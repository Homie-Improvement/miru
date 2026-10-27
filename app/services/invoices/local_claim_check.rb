# frozen_string_literal: true

module Invoices
  # The claim check the remote reservation adapter runs in the monolith
  # before it admits or prepares entries. A live sent invoice that gains a
  # line sends no operation to Timekeeping, so its claim exists only in the
  # monolith's lines and holdings, and Timekeeping alone would let another
  # invoice take the same entry.
  #
  # The request's timesheet_entries rows are locked in id order first, with
  # the lock LegacyReservations takes, and held until the caller's invoice
  # transaction ends, so two invoices adding one entry check in turn. The
  # claims are read after the locks are held, so they include what the
  # previous lock holder committed.
  #
  # Only another kept invoice's active claim is refused here. Whether an
  # entry belongs to the company is left to Timekeeping on prepare and to
  # line validation on admit, so the check treats every entry as in company.
  module LocalClaimCheck
    module_function

    # Returns the request's refused entries as { entry_id:, reason: } pairs.
    def call(request)
      return [] if request.entries.empty?

      TimesheetEntry.where(company_id: request.company_id, id: request.entries)
        .order(:id).lock(LegacyReservations::ROW_LOCK).pluck(:id)
      claims = EntryClaims.new(request.company_id, request.entries)
      request.entries.filter_map do |entry_id|
        result = Timekeeping::ReservationRules.prepare_outcome({
          in_company: true,
          committed: claims.other_active_claim(entry_id, request.invoice_id),
          provisional: false,
          invoice_id: request.invoice_id
        })
        { entry_id:, reason: result.to_s } if Timekeeping::ReservationRules.refusal?(result)
      end
    end
  end
end
