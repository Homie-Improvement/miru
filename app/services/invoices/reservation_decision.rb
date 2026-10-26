# frozen_string_literal: true

module Invoices
  # Decides what an invoice save sends to the reservation port: nil when
  # nothing changes, or the entry set and disposition the invoice should hold.
  #
  # A draft holds what it held plus its lines; a discarded or destroyed draft
  # sends nothing, so its entries stay locked as they do today. A live
  # non-draft sends nothing either: only draft saves lock entries, so a sent
  # invoice saved directly keeps its entries' lock state as it is, and
  # removing its line never releases one. A discarded or destroyed non-draft
  # keeps what it held as retained. A result equal to what is already held
  # sends nothing, so a repeated save or discard never sends an operation
  # that changes nothing.
  module ReservationDecision
    ACTIVE, RETAINED = ReservationRequest::DISPOSITIONS
    DRAFT_STATUS = "draft"
    NOTHING_HELD = { entries: [].freeze, disposition: ACTIVE }.freeze

    SEND_NOTHING = ->(held:, lines:) { nil }

    # Named on its own, apart from the destroyed-draft row, so that changing
    # what a discarded draft sends stays a one-row change.
    DISCARDED_DRAFT = SEND_NOTHING

    RETAIN_HELD = ->(held:, lines:) { { entries: held[:entries], disposition: RETAINED } }

    # Keyed by [draft?, lifecycle]; destroyed takes precedence over discarded.
    TABLE = {
      [true, :live] => ->(held:, lines:) { { entries: held[:entries] | lines, disposition: ACTIVE } },
      [true, :discarded] => DISCARDED_DRAFT,
      [true, :destroyed] => SEND_NOTHING,
      [false, :live] => SEND_NOTHING,
      [false, :discarded] => RETAIN_HELD,
      [false, :destroyed] => RETAIN_HELD
    }.to_h { |key, rule| [key.freeze, rule.freeze] }.freeze

    module_function

    # held: { entries:, disposition: } as the invoice holds it today, or nil
    # when it holds nothing. lines: the entry ids on the invoice's lines.
    def call(status:, discarded:, destroyed:, held:, lines:)
      holding = canonical(held || NOTHING_HELD)
      rule = TABLE.fetch([status.to_s == DRAFT_STATUS, lifecycle(discarded:, destroyed:)])
      result = rule.call(held: holding, lines: ReservationRequest.canonical_entries(lines))
      return if result.nil?

      result = canonical(result)
      result unless result == holding
    end

    def lifecycle(discarded:, destroyed:)
      return :destroyed if destroyed

      discarded ? :discarded : :live
    end

    def canonical(holding)
      { entries: ReservationRequest.canonical_entries(holding.fetch(:entries)), disposition: holding.fetch(:disposition) }
    end

    private_class_method :lifecycle, :canonical
  end
end
