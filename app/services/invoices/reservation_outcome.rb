# frozen_string_literal: true

module Invoices
  # What every reservation adapter returns. Conflicts are a list of
  # { entry_id:, reason: } pairs. reason names why a retryable answer must be
  # retried, such as "unresolved_operation"; it is nil on every other answer.
  # entries lists { entry_id:, company_id: } pairs as the store that answered
  # reports them; only the Timekeeping service's prepare answer carries them,
  # so it is empty on every other answer.
  # The outcome keeps frozen copies of what it is given, so a caller changing
  # its own objects afterwards cannot change an outcome another part of the
  # code already read.
  ReservationOutcome = Data.define(:state, :conflicts, :counts, :reason, :entries) do
    const_set(:STATES, %w[prepared committed aborted refused retryable].freeze)

    def self.frozen_copy(value)
      case value
      when Hash then value.to_h { |key, item| [frozen_copy(key), frozen_copy(item)] }.freeze
      when Array then value.map { |item| frozen_copy(item) }.freeze
      else value.dup.freeze
      end
    end

    def initialize(state:, conflicts:, counts:, reason: nil, entries: [])
      raise ArgumentError, "unknown state #{state.inspect}" unless self.class::STATES.include?(state)

      conflicts = Array(conflicts).map { |conflict| { entry_id: conflict.fetch(:entry_id), reason: conflict.fetch(:reason) } }
      entries = Array(entries).map { |entry| { entry_id: entry.fetch(:entry_id), company_id: entry.fetch(:company_id) } }
      super(
        state: state.dup.freeze, conflicts: self.class.frozen_copy(conflicts),
        counts: self.class.frozen_copy(counts.to_h), reason: reason&.dup&.freeze,
        entries: self.class.frozen_copy(entries)
      )
    end
  end
end
