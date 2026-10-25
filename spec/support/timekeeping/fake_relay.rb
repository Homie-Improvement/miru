# frozen_string_literal: true

require_relative "client"
require_relative "contract"
require_relative "fake_timekeeping"
require_relative "idempotency_receipts"

module TimekeepingContract
  # The relay that carries a fake Timekeeping's outbox to the monolith, with
  # the in-memory projection endpoint it delivers to
  # (POST /internal/v1/timekeeping/entry-snapshots). The projection consumer
  # lane builds against it.
  #
  # Every rule the snapshot examples check is a named policy passed in at
  # construction, so the mutation spec can break one rule at a time.
  class FakeRelay
    DELIVER_OPERATION = "deliver"

    POLICIES = {
      # The current owner's generation, or during a handoff the previous one
      # up to the outbox position captured when that owner was frozen.
      generation_accepted: lambda do |generation:, outbox_position:, current:, handoff:|
        generation == current ||
          (!handoff.nil? && generation == handoff[:previous_generation] && outbox_position <= handoff[:final_outbox_position])
      end,
      apply_version: ->(incoming:, stored:) { stored.nil? || incoming > stored },
      # A discard is kept as a row with discarded_at set, never deleted.
      delete_tombstones: false,
      receipt_key: IdempotencyReceipts::SCOPED_RECEIPT_KEY,
      reject_reused_key: true
    }.freeze

    attr_reader :generation

    def initialize(source:, policies: POLICIES)
      @source = source
      @policies = POLICIES.merge(policies)
      @contract = TimekeepingContract.load(:entry_snapshots)
      @router = Router.new(@contract.fetch("routes"))
      @receipts = IdempotencyReceipts.new(receipt_key: @policies[:receipt_key], reject_reused_key: @policies[:reject_reused_key])
      @generation = FakeTimekeeping::INITIAL_GENERATION
      @handoff = nil
      @projection = {}
      @sent_position = 0
    end

    def generation=(generation)
      @generation = Integer(generation)
    end

    def begin_handoff(previous_generation:, final_outbox_position:)
      @handoff = { previous_generation:, final_outbox_position: }
    end

    def flip_ownership
      @handoff = nil
    end

    def projected_entry(entry_id)
      Wire.copy(@projection[entry_id])
    end

    # The batch the relay sends next: every unsent outbox row, in
    # outbox_position order.
    def next_batch
      snapshots = @source.outbox.select { |item| item.fetch("outbox_position") > @sent_position }
      Wire.copy("schema_version" => @contract.fetch("schema_version"), "snapshots" => snapshots)
    end

    # Sends the next batch to the projection endpoint and marks its rows sent
    # only after a 200, so delivery is at least once.
    def deliver_pending(credential:, idempotency_key:)
      batch = next_batch
      response = call("POST", @contract.dig("routes", DELIVER_OPERATION, "path"),
                      headers: { "Authorization" => "Bearer #{credential}", "Idempotency-Key" => idempotency_key }, body: batch)
      @sent_position = batch["snapshots"].last.fetch("outbox_position") if response.status == 200 && batch["snapshots"].any?
      response
    end

    def call(method, path, headers: {}, body: nil)
      headers = headers.to_h
      batch = Wire.copy(body) || {}
      return Wire.error(@contract, "not_found") unless @router.match(method, path)

      credential = Wire.bearer(headers)
      service = @source.service(credential)
      return Wire.error(@contract, "unauthorized") unless service || @source.user_token?(credential)
      return Wire.error(@contract, "forbidden") unless service&.fetch("operations")&.include?(DELIVER_OPERATION)

      snapshots = Array(batch["snapshots"])
      company_scope = snapshots.map { |item| item.dig("entry", "company_id") }.uniq.sort
      @receipts.answer(company_scope:, actor: ["service", service["name"]], operation: DELIVER_OPERATION,
                       key: headers["Idempotency-Key"], body: batch) do
        apply(snapshots)
      end
    end

    private

      # A batch with any refused snapshot applies nothing, because the relay
      # re-sends a batch that did not get a 200.
      def apply(snapshots)
        refused = snapshots.any? do |item|
          !@policies[:generation_accepted].call(generation: item["generation"], outbox_position: item["outbox_position"],
                                                current: @generation, handoff: @handoff)
        end
        return Wire.error(@contract, "stale_generation") if refused

        applied = snapshots.count { |item| upsert(item.fetch("entry")) }
        Response.new(status: 200, body: { "applied" => applied, "ignored" => snapshots.size - applied })
      end

      def upsert(entry)
        stored = @projection[entry["id"]]
        return false unless @policies[:apply_version].call(incoming: entry["version"], stored: stored&.fetch("version"))

        if entry["discarded_at"] && @policies[:delete_tombstones]
          @projection.delete(entry["id"])
        else
          @projection[entry["id"]] = entry
        end
        true
      end
  end
end
