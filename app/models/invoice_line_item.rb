# frozen_string_literal: true

class InvoiceLineItem < ApplicationRecord
  include BillingFenced

  belongs_to :invoice
  belongs_to :timesheet_entry, optional: true
  has_many :invoice_line_item_time_entries, dependent: :destroy
  has_many :linked_timesheet_entries, through: :invoice_line_item_time_entries, source: :timesheet_entry

  # Registered before the links are replaced and before the dependent join
  # rows are destroyed, so the reservation boundary captures the entries the
  # invoice referenced before this change.
  before_save :register_reservation_change_on_save
  before_destroy :register_reservation_change, prepend: true
  before_save :link_pending_linked_timesheet_entries
  before_update :capture_previous_invoice_id, if: :will_save_change_to_invoice_id?
  after_save :sync_invoice_totals
  after_destroy :sync_invoice_totals

  validates :name, :date, :rate, :quantity, presence: true
  validates :rate, numericality: { greater_than_or_equal_to: 0 }
  validates :quantity, numericality: { greater_than_or_equal_to: 0 }
  # Manual lines keep a NULL timesheet_entry_id. Once Timekeeping owns the
  # entries, the projection lags, so these checks would refuse an entry the
  # relay has not delivered yet; the reservation boundary checks every added
  # entry at commit instead, against Timekeeping's prepare answer.
  validate :timesheet_entry_found_in_invoice_company,
    if: -> { !timesheet_entry_id.nil? && entries_checked_by_projection? }
  validate :linked_timesheet_entries_found_in_invoice_company, if: :entries_checked_by_projection?

  def self.total_cost_of_all_line_items
    (self.sum("quantity * rate") / 60.0).round(3)
  end

  def hours_spent
    @_hours_spent ||= quantity.to_f / 60.0
  end

  def minutes_spent
    @_minutes_spent ||= quantity.to_f % 60.0
  end

  def time_spent
    if quantity <= 0
      "00:00"
    else
      hours = hours_spent.to_i
      hours = "0#{hours}" if hours.digits.count == 1

      minutes = minutes_spent.to_i
      minutes = "0#{minutes}" if minutes.digits.count == 1

      "#{hours}:#{minutes}"
    end
  end

  def total_cost
    @_total_cost ||= (hours_spent * rate).round(3)
  end

  def formatted_date
    CompanyDateFormattingService.new(date, company: invoice.company).process
  end

  # The Rails ids writer would look the ids up in every company, and raise
  # RecordNotFound for a missing one, so a caller could tell a missing id from
  # another company's id. The ids are kept here and resolved within the
  # invoice's company at validation and save, when nested attributes have set
  # the invoice.
  def linked_timesheet_entry_ids=(ids)
    id_type = TimesheetEntry.type_for_attribute(:id)
    @pending_linked_timesheet_entry_ids = Array(ids).reject(&:blank?).map { |id| id_type.cast(id) }.uniq
  end

  # The linked entry ids as the link rows store them. The through reader joins
  # timesheet_entries, which leaves out an entry the relay has not projected
  # yet, so an editor resubmitting the ids it was shown would drop that link.
  def linked_entry_ids_on_rows
    invoice_line_item_time_entries.map(&:timesheet_entry_id)
  end

  # Nested invoice saves validate and save only children that report a change.
  # Pending linked ids change no column, so they are counted here.
  def changed_for_autosave?
    super || pending_linked_timesheet_entry_ids?
  end

  private

    def entries_in_invoice_company
      return TimesheetEntry.none if invoice.blank?

      TimesheetEntry.where(company_id: invoice.company_id)
    end

    def pending_linked_timesheet_entry_ids?
      !@pending_linked_timesheet_entry_ids.nil?
    end

    # The pending ids' entries, or nil when any id is not an entry of the
    # invoice's company. The rows are key-share locked, like the direct entry,
    # so none can be deleted between this lookup and the save's commit.
    def pending_linked_entries_in_invoice_company
      requested_ids = @pending_linked_timesheet_entry_ids
      entries = entries_in_invoice_company.where(id: requested_ids.compact).lock("FOR KEY SHARE").to_a
      entries if entries.size == requested_ids.size
    end

    # Assigning links on a saved line writes join rows at once, so it waits for
    # save and validation stays read-only. Ids that stopped resolving after
    # validation refuse the save rather than leave the old links in place.
    def link_pending_linked_timesheet_entries
      return unless pending_linked_timesheet_entry_ids?
      return link_pending_linked_timesheet_entry_ids unless entries_checked_by_projection?

      entries = pending_linked_entries_in_invoice_company
      if entries.nil?
        errors.add(:linked_timesheet_entries, :not_found)
        throw :abort
      end

      self.linked_timesheet_entries = entries
      @pending_linked_timesheet_entry_ids = nil
    end

    # Links the pending ids by id, because the projection may not hold their
    # rows yet. Links to ids no longer named are destroyed now; new ones are
    # saved with this line. The reservation boundary refuses the save at
    # commit when any new id is not the invoice company's entry.
    def link_pending_linked_timesheet_entry_ids
      requested_ids = @pending_linked_timesheet_entry_ids
      kept_links, dropped_links = invoice_line_item_time_entries.partition do |link|
        requested_ids.include?(link.timesheet_entry_id)
      end
      invoice_line_item_time_entries.destroy(*dropped_links) if dropped_links.any?
      (requested_ids - kept_links.map(&:timesheet_entry_id)).each do |entry_id|
        invoice_line_item_time_entries.build(timesheet_entry_id: entry_id)
      end
      @pending_linked_timesheet_entry_ids = nil
    end

    def entries_checked_by_projection?
      Invoices::EntryReferenceCheck.for(TimekeepingOwnership.current) == :projection
    end

    # Missing ids, other companies' ids and entries with no company get the same
    # error, so no response shows whether an id exists in another company.
    # No database key checks timesheet_entry_id, so the row is locked to stop it
    # being deleted before this save commits. FOR KEY SHARE still blocks a
    # delete but not the later update of the entry's locked flag; FOR SHARE
    # would deadlock two invoices saving the same entry at once.
    def timesheet_entry_found_in_invoice_company
      return if entries_in_invoice_company.where(id: timesheet_entry_id).lock("FOR KEY SHARE").exists?

      errors.add(:timesheet_entry, :not_found)
    end

    # Pending ids replace the current links at save, so only they are checked;
    # links that the replacement removes do not block it.
    def linked_timesheet_entries_found_in_invoice_company
      found = if pending_linked_timesheet_entry_ids?
        !pending_linked_entries_in_invoice_company.nil?
      else
        invoice.blank? || linked_timesheet_entries.all? { |entry| entry.company_id == invoice.company_id }
      end

      errors.add(:linked_timesheet_entries, :not_found) unless found
    end

    def associated_timesheet_entry_ids
      ([timesheet_entry_id] + linked_timesheet_entry_ids).compact.uniq
    end

    # A line moved to another invoice changes the entries of both.
    def register_reservation_change(added_references = [])
      Invoices::ReservationBoundary.register(invoice, added_references:) if invoice
      return unless will_save_change_to_invoice_id? && invoice_id_in_database

      previous_invoice = Invoice.find_by(id: invoice_id_in_database)
      Invoices::ReservationBoundary.register(previous_invoice) if previous_invoice
    end

    # A new or retargeted direct entry is a new reference, and a line moved to
    # another invoice brings its direct entry and its stored links there as new
    # references, so the boundary checks each one at commit. New links register
    # their own entry when they are saved.
    def register_reservation_change_on_save
      added_references = []
      if timesheet_entry_id &&
         (new_record? || will_save_change_to_timesheet_entry_id? || will_save_change_to_invoice_id?)
        stored = [timesheet_entry_id_in_database, invoice_id_in_database] if persisted?
        added_references << [self, timesheet_entry_id, stored]
      end
      if persisted? && will_save_change_to_invoice_id?
        InvoiceLineItemTimeEntry.where(invoice_line_item_id: id).find_each do |link|
          added_references << [link, link.timesheet_entry_id, [link.timesheet_entry_id, invoice_id_in_database]]
        end
      end
      register_reservation_change(added_references)
    end

    def capture_previous_invoice_id
      @previous_invoice_id = invoice_id_was
    end

    def sync_invoice_totals
      return unless should_sync_invoice_totals?

      invoice_ids_to_sync.each do |current_invoice_id|
        next if skip_invoice_sync?(current_invoice_id)

        invoice = Invoice.find_by(id: current_invoice_id)
        next unless invoice

        invoice.sync_totals_from_line_items!
      end
    ensure
      @previous_invoice_id = nil
    end

    def should_sync_invoice_totals?
      destroyed? ||
        previous_changes.key?("id") ||
        previous_changes.key?("invoice_id") ||
        previous_changes.key?("quantity") ||
        previous_changes.key?("rate")
    end

    def invoice_ids_to_sync
      ids = [invoice_id]
      ids << @previous_invoice_id if defined?(@previous_invoice_id)
      ids << previous_changes.dig("invoice_id", 0)
      ids.compact.uniq
    end

    def skip_invoice_sync?(current_invoice_id)
      invoice.present? &&
        invoice.id == current_invoice_id &&
        invoice.skip_line_item_total_sync
    end
end
