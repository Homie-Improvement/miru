# frozen_string_literal: true

require "digest"
require "yaml"

module Timekeeping
  # Idempotency receipts for entry snapshot deliveries
  # (contracts/timekeeping/idempotency.yml, key_sources.entry_snapshots).
  # The same key and batch get the first answer back; the same key with a new
  # batch answers idempotency_key_reused. Only a 200 is stored, so a refused
  # batch is evaluated again on retry.
  #
  # Runs inside the projection consumer's transaction and before its
  # generation check: a relay that lost a 200 and retries after the ownership
  # flip must get its first answer, not 409.
  class SnapshotDeliveryReceipts
    CONTRACT = YAML.safe_load_file(Rails.root.join("contracts/timekeeping/idempotency.yml")).freeze
    RETENTION = CONTRACT.fetch("retention_hours").hours
    KEY_REUSED = ProjectionConsumer::Result.new(
      status: CONTRACT.dig("errors", "key_reused", "status"),
      body: CONTRACT.dig("errors", "key_reused", "body").freeze
    )
    # The monolith accepts one service identity, TIMEKEEPING_SERVICE_TOKEN,
    # so every receipt belongs to that one actor.
    ACTOR = "timekeeping"

    # A delivery without an Idempotency-Key is applied without a receipt; the
    # version guard still keeps a repeat from changing data.
    def initialize(key:, batch:, company_ids:)
      @key = key.presence
      @digest = Digest::SHA256.hexdigest(canonical_json(batch))
      @scope = { company_ids: company_ids.uniq.sort, actor: ACTOR, key: @key }
    end

    # The answer to replay, or nil when this delivery must be applied.
    def stored_answer
      return nil unless @key

      lock_key
      receipt = EntrySnapshotReceipt.find_by(@scope)
      return nil unless receipt

      if receipt.expires_at <= Time.current
        # An expired receipt no longer answers; deleting it makes room for the new one.
        receipt.destroy!
        return nil
      end
      return KEY_REUSED if receipt.request_digest != @digest

      ProjectionConsumer::Result.new(status: receipt.response_status, body: receipt.response_body)
    end

    # Stores a 200 answer and returns it unchanged.
    def store(result)
      if @key && result.status == 200
        now = Time.current
        EntrySnapshotReceipt.create!(**@scope, request_digest: @digest, response_status: result.status,
                                     response_body: result.body, created_at: now, expires_at: now + RETENTION)
      end
      result
    end

    private

      # Serializes deliveries that share a key, so two concurrent retries
      # cannot both miss the receipt and both apply.
      def lock_key
        EntrySnapshotReceipt.connection.execute(EntrySnapshotReceipt.sanitize_sql_array(
          ["SELECT pg_advisory_xact_lock(hashtextextended(?, 0))", "entry_snapshot_receipt:#{@key}"]
        ))
      end

      # Hash key order must not change the digest of the same batch.
      def canonical_json(value)
        case value
        when Hash then "{#{value.sort_by { |key, _| key.to_s }.map { |key, item| "#{key.to_s.to_json}:#{canonical_json(item)}" }.join(",")}}"
        when Array then "[#{value.map { |item| canonical_json(item) }.join(",")}]"
        else value.to_json
        end
      end
  end
end
