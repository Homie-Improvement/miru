# frozen_string_literal: true

require "json"

module Timekeeping
  # The legacy create receipts the first cutover checkpoint carries into
  # Timekeeping, so a create the legacy store committed and whose answer the
  # client lost replays from Timekeeping when the retry arrives after the flip,
  # instead of recording the same time twice.
  #
  # Each live receipt becomes the idempotency_records row Timekeeping's
  # entry writer would have stored for that create: the operation and status
  # of its create route, the fingerprint of the body the monolith forwards,
  # and the answer rebuilt from the entry as the first attempt committed it.
  #
  # Pure: it reads plain hashes and touches no database.
  module LegacyCreateReceiptConversion
    # Timekeeping's receipt operation is "#{route} #{target_id}"; a create has
    # no target, so its operation ends in a space.
    CREATE_OPERATION = "create "
    CREATED_STATUS = 201
    USER_ACTOR_TYPE = "user"

    module_function

    # receipts: [{ id:, company_id:, actor_kind:, actor_id:, key:,
    # forwarded_body:, entry_values:, created_at:, expires_at: }], where
    # forwarded_body is the JSON text of the body a forwarded create of the
    # same request sends, or nil for a receipt written before it was stored,
    # and entry_values holds the committed entry's response fields as JSON
    # values.
    #
    # Returns { rows:, refusals: }: rows sorted by id, and refusals as
    # { company_id => [message] }. A receipt that expired at or before
    # captured_at is left out, because the legacy store no longer answers it
    # either. A live receipt without a forwarded body cannot be carried, and
    # leaving it out would let its retry record a second entry, so it refuses
    # the cutover until it expires.
    def convert(receipts:, captured_at:)
      live = receipts.select { |receipt| receipt[:expires_at] > captured_at }.sort_by { |receipt| receipt[:id] }
      carried, uncarried = live.partition { |receipt| receipt[:forwarded_body] }

      {
        rows: carried.map { |receipt| row_for(receipt) },
        refusals: uncarried.group_by { |receipt| receipt[:company_id] }.transform_values do |company_receipts|
          company_receipts.map { |receipt| refusal_for(receipt) }
        end
      }
    end

    def row_for(receipt)
      {
        "id" => receipt[:id],
        "company_id" => receipt[:company_id],
        "actor_type" => USER_ACTOR_TYPE,
        "actor_id" => receipt[:actor_id],
        "operation" => CREATE_OPERATION,
        "key" => LegacyCreateReplay.carried_key(actor_kind: receipt[:actor_kind], key: receipt[:key]),
        "fingerprint" => LegacyCreateReplay.forwarded_fingerprint(receipt[:forwarded_body]),
        "status" => CREATED_STATUS,
        "body" => JSON.generate(answer_for(receipt)),
        "created_at" => receipt[:created_at]
      }
    end

    # The receipt's company, not the stored row's, names the answer's company:
    # the receipt was written for that company's request.
    def answer_for(receipt)
      LocalOwner::RESPONSE_FIELDS.index_with { |field| receipt[:entry_values][field] }
        .merge("company_id" => receipt[:company_id])
    end

    def refusal_for(receipt)
      "legacy create receipt #{receipt[:id]} was written before its forwarded body was stored, " \
        "so it cannot be carried; run the cutover again after it expires at #{receipt[:expires_at].utc.iso8601}"
    end
  end
end
