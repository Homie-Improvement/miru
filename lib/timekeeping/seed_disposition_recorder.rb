# frozen_string_literal: true

module Timekeeping
  # Loads the demo seed into an empty database, reads each company's entries
  # and invoice links, and writes the recorded seed disposition. The decisions
  # live in Timekeeping::Preflight and Timekeeping::SeedDisposition; this module
  # only reads and writes.
  module SeedDispositionRecorder
    SEED_PATH = Rails.root.join("db/seeds.rb")
    DEFAULT_PATH = Rails.root.join("spec/fixtures/timekeeping/seed_disposition.yml")
    # Rails' own bookkeeping tables, which hold rows in every migrated database.
    METADATA_TABLES = %w[ar_internal_metadata schema_migrations].freeze

    class Error < StandardError; end

    module_function

    def generate!(path:, as_of:)
      load_fresh_seed!(as_of:)
      write!(path:, as_of:)
    end

    # The seed finds users by email and rewrites them, and it destroys and
    # recreates invoice line items, which changes lock state. Loading it over
    # any existing row would record a disposition of data that never was the
    # seed, so every application table must be empty first.
    #
    # Which seeded entries exist depends on user ids, so the id sequences are
    # reset before the load: two loads at the same as_of give the same ids.
    def load_fresh_seed!(as_of:)
      tables = application_tables
      occupied = tables.select { |table| table_has_rows?(table) }
      if occupied.any?
        raise Error, "Refusing to load the seed over existing data in: #{occupied.sort.join(', ')}"
      end

      tables.each { |table| connection.reset_pk_sequence!(table) }
      with_seed_as_of(as_of) { load SEED_PATH.to_s }
    end

    # Writes the disposition of the data already in the database, without
    # loading the seed. The file is written only when every company classifies
    # cleanly, and it replaces the previous file in one rename.
    def write!(path:, as_of:)
      disposition = SeedDisposition.record(classify_companies, as_of:)
      write_atomically(path, to_yaml(disposition))
      disposition
    end

    # Entry id lists are written inline, wrapped at the emitter's line width,
    # so the reviewed file reads one invoice per few lines rather than one
    # entry id per line.
    def to_yaml(disposition)
      document = Psych.parse_stream(YAML.dump(disposition))
      document.grep(Psych::Nodes::Sequence).each { |sequence| sequence.style = Psych::Nodes::Sequence::FLOW }
      document.to_yaml
    end

    # { company_name => { classification:, invoice_numbers: } } for every
    # company, each classified on its own data. Raises when a company has
    # orphans, conflicts, or invoices that link another company's entries.
    def classify_companies
      Company.order(:name).to_h do |company|
        facts = snapshot(company)
        classification = Preflight.classify(entries: facts[:entries], links: facts[:links])
        refuse_unsafe!(company, facts, classification)
        [company.name, { classification:, invoice_numbers: facts[:invoices] }]
      end
    end

    # A company's entries, the links from its invoices (direct line items and
    # grouped line-item join rows), and its invoice numbers by id. Discarded
    # invoices and entries are included: the classifier needs them.
    def snapshot(company)
      invoices = Invoice.where(company_id: company.id).pluck(:id, :invoice_number, :status, :discarded_at)
      invoice_facts = invoices.to_h { |id, _number, status, discarded_at| [id, { draft: status == "draft", discarded: discarded_at.present? }] }

      {
        entries: company_entries(company),
        links: invoice_links(invoice_facts.keys).map { |invoice_id, entry_id| { entry_id:, invoice_id:, **invoice_facts.fetch(invoice_id) } },
        invoices: invoices.to_h { |id, number, _status, _discarded_at| [id, number] }
      }
    end

    def company_entries(company)
      TimesheetEntry.joins(project: :client).where(clients: { company_id: company.id })
        .pluck(:id, :locked).map { |id, locked| { id:, locked: } }
    end

    def invoice_links(invoice_ids)
      direct = InvoiceLineItem.where(invoice_id: invoice_ids).where.not(timesheet_entry_id: nil)
        .pluck(:invoice_id, :timesheet_entry_id)
      grouped = InvoiceLineItemTimeEntry.joins(:invoice_line_item).where(invoice_line_items: { invoice_id: invoice_ids })
        .pluck("invoice_line_items.invoice_id", :timesheet_entry_id)
      direct + grouped
    end

    def refuse_unsafe!(company, facts, classification)
      foreign_entry_ids = facts[:links].pluck(:entry_id).uniq - facts[:entries].pluck(:id)
      problems = {
        "invoices linking entries of another company" => foreign_entry_ids,
        "orphans" => classification[:orphans],
        "conflicts" => classification[:conflicts]
      }.reject { |_label, entry_ids| entry_ids.empty? }
      return if problems.empty?

      details = problems.map { |label, entry_ids| "#{label}: entries #{entry_ids.sort.join(', ')}" }
      raise Error, "#{company.name} has #{details.join('; ')}"
    end

    def write_atomically(path, content)
      path = Pathname(path)
      FileUtils.mkdir_p(path.dirname)
      temp_path = path.dirname.join(".#{path.basename}.#{Process.pid}.tmp")
      File.write(temp_path, content)
      File.rename(temp_path, path)
    ensure
      FileUtils.rm_f(temp_path) if temp_path
    end

    def with_seed_as_of(as_of)
      previous = ENV.fetch("MIRU_SEED_AS_OF", nil)
      ENV["MIRU_SEED_AS_OF"] = as_of.to_s
      yield
    ensure
      ENV["MIRU_SEED_AS_OF"] = previous
    end

    def application_tables
      connection.tables - METADATA_TABLES
    end

    def table_has_rows?(table)
      connection.select_value("SELECT 1 FROM #{connection.quote_table_name(table)} LIMIT 1").present?
    end

    def connection
      ActiveRecord::Base.connection
    end
  end
end
