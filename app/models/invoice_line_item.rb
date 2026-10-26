# frozen_string_literal: true

class InvoiceLineItem < ApplicationRecord
  belongs_to :invoice
  belongs_to :timesheet_entry, optional: true
  has_many :invoice_line_item_time_entries, dependent: :destroy
  has_many :linked_timesheet_entries, through: :invoice_line_item_time_entries, source: :timesheet_entry

  before_validation :resolve_pending_linked_timesheet_entries
  before_update :capture_previous_invoice_id, if: :will_save_change_to_invoice_id?
  before_destroy :unlock_timesheet_entries
  after_save :sync_invoice_totals
  after_destroy :sync_invoice_totals

  validates :name, :date, :rate, :quantity, presence: true
  validates :rate, numericality: { greater_than_or_equal_to: 0 }
  validates :quantity, numericality: { greater_than_or_equal_to: 0 }
  # Manual lines keep a NULL timesheet_entry_id.
  validate :timesheet_entry_found_in_invoice_company, unless: -> { timesheet_entry_id.nil? }
  validate :linked_timesheet_entries_found_in_invoice_company

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
  # invoice's company at validation, when nested attributes have set the invoice.
  def linked_timesheet_entry_ids=(ids)
    @pending_linked_timesheet_entry_ids = Array(ids).reject(&:blank?).map { |id| Integer(id.to_s, exception: false) }.uniq
  end

  # Nested invoice saves validate and save only children that report a change.
  # Pending linked ids change no column, so they are counted here.
  def changed_for_autosave?
    super || !@pending_linked_timesheet_entry_ids.nil?
  end

  private

    def entries_in_invoice_company
      return TimesheetEntry.none if invoice.blank?

      TimesheetEntry.where(company_id: invoice.company_id)
    end

    # Links the pending ids only when every one is an entry of the invoice's
    # company; otherwise they stay pending and validation reports not found.
    def resolve_pending_linked_timesheet_entries
      requested_ids = @pending_linked_timesheet_entry_ids
      return if requested_ids.nil?

      entries = entries_in_invoice_company.where(id: requested_ids.compact).to_a
      return unless entries.size == requested_ids.size

      self.linked_timesheet_entries = entries
      @pending_linked_timesheet_entry_ids = nil
    end

    # Missing ids, other companies' ids and entries with no company get the same
    # error, so no response shows whether an id exists in another company.
    # No database key checks timesheet_entry_id, so the row is share-locked to
    # stop it being deleted before this save commits.
    def timesheet_entry_found_in_invoice_company
      return if entries_in_invoice_company.where(id: timesheet_entry_id).lock("FOR SHARE").exists?

      errors.add(:timesheet_entry, :not_found)
    end

    def linked_timesheet_entries_found_in_invoice_company
      unresolved_ids = !@pending_linked_timesheet_entry_ids.nil?
      foreign_entry = invoice.present? &&
        linked_timesheet_entries.any? { |entry| entry.company_id != invoice.company_id }

      errors.add(:linked_timesheet_entries, :not_found) if unresolved_ids || foreign_entry
    end

    def unlock_timesheet_entries
      return unless invoice.draft?

      TimesheetEntry.where(id: associated_timesheet_entry_ids).update!(locked: false)
    end

    def associated_timesheet_entry_ids
      ([timesheet_entry_id] + linked_timesheet_entry_ids).compact.uniq
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
