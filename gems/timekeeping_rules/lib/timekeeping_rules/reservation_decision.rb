# frozen_string_literal: true

module TimekeepingRules
  # The reservation decision table of docs/architecture/timekeeping-soa.md
  # section 7.2, as a pure function over plain values, so the Timekeeping
  # service and the monolith's invoice boundary decide alike.
  module ReservationDecision
    DRAFT_STATUS = "draft"
    ACTIVE_DISPOSITION = "active"
    COMMITTED = "committed"
    PROVISIONAL = "provisional"

    # Prepare outcome for one desired entry as [condition, outcome]. The first
    # row whose condition holds decides. Only an active invoice's committed
    # reservation refuses another invoice; an entry that only a retained
    # invoice holds can still be reserved.
    PREPARE_TABLE = [
      [->(facts) { !facts[:in_company] }, :not_found],
      [->(facts) { facts[:provisional] }, :provisional_elsewhere],
      [->(facts) { facts[:committed_by_this] }, :keep],
      [->(facts) { facts[:committed_by_other_active] }, :on_another_invoice],
      [->(_facts) { true }, :reserve]
    ].map(&:freeze).freeze

    CONFLICT_OUTCOMES = %i[not_found provisional_elsewhere on_another_invoice].freeze

    module_function

    # current: maps each entry id found in the invoice's company to its
    # reservations, each { invoice: :this | :other, state:, disposition: }.
    # An id missing from current is outside the company or does not exist.
    # desired: the invoice's lines; a direct line is an entry id and a grouped
    # line is an array of ids. Returns { reserve: [ids], release: [ids],
    # conflicts: [{ entry_id:, reason: }] }.
    def call(current:, desired:, disposition:, invoice_status:)
      desired_ids = desired.flatten.uniq
      outcomes = desired_ids.map { |entry_id| [entry_id, prepare_outcome(current[entry_id])] }

      {
        reserve: outcomes.filter_map { |entry_id, outcome| entry_id if outcome == :reserve },
        release: release(current:, desired_ids:, disposition:, invoice_status:),
        conflicts: outcomes.filter_map do |entry_id, outcome|
          { entry_id:, reason: outcome } if CONFLICT_OUTCOMES.include?(outcome)
        end
      }
    end

    def prepare_outcome(reservations)
      facts = entry_facts(reservations)
      PREPARE_TABLE.find { |condition, _outcome| condition.call(facts) }.last
    end
    private_class_method :prepare_outcome

    def entry_facts(reservations)
      return { in_company: false } if reservations.nil?

      {
        in_company: true,
        provisional: reservations.any? { |reservation| reservation[:state] == PROVISIONAL },
        committed_by_this: reservations.any? { |reservation| committed_by?(reservation, :this) },
        committed_by_other_active: reservations.any? do |reservation|
          committed_by?(reservation, :other) && reservation[:disposition] == ACTIVE_DISPOSITION
        end
      }
    end
    private_class_method :entry_facts

    # Only an active draft gives entries back. Row L4: "On a non-draft, the
    # boundary sends no removal", and a retained invoice keeps what it holds.
    # Any other status or disposition releases nothing, so an unknown value
    # can never unlock an entry. An entry still named by any remaining direct
    # or grouped line stays reserved.
    def release(current:, desired_ids:, disposition:, invoice_status:)
      return [] unless invoice_status == DRAFT_STATUS && disposition == ACTIVE_DISPOSITION

      held = current.filter_map do |entry_id, reservations|
        entry_id if reservations.any? { |reservation| committed_by?(reservation, :this) }
      end
      held - desired_ids
    end
    private_class_method :release

    def committed_by?(reservation, invoice)
      reservation[:invoice] == invoice && reservation[:state] == COMMITTED
    end
    private_class_method :committed_by?
  end
end
