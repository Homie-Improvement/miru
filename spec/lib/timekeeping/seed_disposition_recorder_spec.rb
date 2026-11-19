# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::SeedDispositionRecorder do
  let(:company) { create(:company, name: "Recorder Co") }
  let(:client) { create(:client, company:) }
  let(:project) { create(:project, client:, billable: true) }
  let(:entry_owner) { create(:user, current_workspace_id: company.id) }

  def recorder_spec_entry(locked: false)
    entry = create(:timesheet_entry, user: entry_owner, project:, bill_status: "unbilled")
    entry.update_columns(locked:)
    entry
  end

  def recorder_spec_aggregate_line(invoice, linked_entries)
    line = create(:invoice_line_item, invoice:, timesheet_entry: nil, rate: 100, quantity: 120)
    linked_entries.each do |entry|
      create(:invoice_line_item_time_entry, invoice_line_item: line, timesheet_entry: entry)
    end
    line
  end

  def recorder_spec_sent_invoice(number)
    create(:invoice, company:, client:, invoice_number: number, status: :sent)
  end

  describe ".load_fresh_seed!" do
    it "refuses a database holding only a user with no company, and leaves that user unchanged" do
      user = create(:user, email: "dana@forkandleaf.example", current_workspace: nil, first_name: "Existing")
      Company.delete_all
      before = user.reload.attributes.slice("first_name", "last_name", "encrypted_password", "current_workspace_id")

      expect { described_class.load_fresh_seed!(as_of: "2026-10-23") }
        .to raise_error(described_class::Error, /users/)

      expect(user.reload.attributes.slice("first_name", "last_name", "encrypted_password", "current_workspace_id"))
        .to eq(before)
      expect(Company.count).to eq(0)
    end

    it "refuses a database holding a company and leaves its entries' lock state unchanged" do
      locked_entry = recorder_spec_entry(locked: true)
      unlocked_entry = recorder_spec_entry(locked: false)

      expect { described_class.load_fresh_seed!(as_of: "2026-10-23") }
        .to raise_error(described_class::Error, /companies/)

      expect(locked_entry.reload.locked).to be(true)
      expect(unlocked_entry.reload.locked).to be(false)
      expect(Company.pluck(:name)).to eq(["Recorder Co"])
    end
  end

  describe ".snapshot" do
    it "reads direct and grouped links, with each invoice's draft and discarded state" do
      direct_entry = recorder_spec_entry
      grouped_entry = recorder_spec_entry
      invoice = recorder_spec_sent_invoice("RC-0001")
      create(:invoice_line_item, invoice:, timesheet_entry: direct_entry, rate: 100, quantity: 60)
      recorder_spec_aggregate_line(invoice, [grouped_entry])

      facts = described_class.snapshot(company)

      expect(facts[:entries]).to contain_exactly(
        { id: direct_entry.id, locked: false }, { id: grouped_entry.id, locked: false })
      expect(facts[:links]).to contain_exactly(
        { entry_id: direct_entry.id, invoice_id: invoice.id, draft: false, discarded: false },
        { entry_id: grouped_entry.id, invoice_id: invoice.id, draft: false, discarded: false })
      expect(facts[:invoices]).to eq(invoice.id => "RC-0001")
    end

    it "includes discarded invoices and entries, with their draft and discarded state" do
      retained_entry = recorder_spec_entry(locked: true)
      relocked_entry = recorder_spec_entry(locked: true)
      retained_entry.update_columns(discarded_at: Time.current)
      discarded_sent = recorder_spec_sent_invoice("RC-0003")
      recorder_spec_aggregate_line(discarded_sent, [retained_entry])
      discarded_draft = create(:invoice, company:, client:, invoice_number: "RC-0004")
      recorder_spec_aggregate_line(discarded_draft, [relocked_entry])
      [discarded_sent, discarded_draft].each { |invoice| invoice.update_columns(discarded_at: Time.current) }

      facts = described_class.snapshot(company)

      expect(facts[:entries]).to contain_exactly(
        { id: retained_entry.id, locked: true }, { id: relocked_entry.id, locked: true })
      expect(facts[:links]).to contain_exactly(
        { entry_id: retained_entry.id, invoice_id: discarded_sent.id, draft: false, discarded: true },
        { entry_id: relocked_entry.id, invoice_id: discarded_draft.id, draft: true, discarded: true })
      expect(facts[:invoices]).to eq(discarded_sent.id => "RC-0003", discarded_draft.id => "RC-0004")

      classification = Timekeeping::Preflight.classify(entries: facts[:entries], links: facts[:links])
      expect(classification[:retained]).to eq([retained_entry.id])
      expect(classification[:relock_releases]).to eq([relocked_entry.id])
    end
  end

  describe ".write!" do
    around do |example|
      Dir.mktmpdir do |dir|
        @recorder_spec_path = File.join(dir, "seed_disposition.yml")
        example.run
      end
    end

    it "records a non-draft invoice's unlocked entries, grouped ones included, as reserved" do
      direct_entry = recorder_spec_entry
      grouped_entry = recorder_spec_entry
      invoice = recorder_spec_sent_invoice("RC-0001")
      create(:invoice_line_item, invoice:, timesheet_entry: direct_entry, rate: 100, quantity: 60)
      recorder_spec_aggregate_line(invoice, [grouped_entry])
      expect([direct_entry, grouped_entry].map { |entry| entry.reload.locked }).to eq([false, false])

      described_class.write!(path: @recorder_spec_path, as_of: "2026-10-23")

      expect(YAML.load_file(@recorder_spec_path)).to eq(
        "as_of" => "2026-10-23",
        "companies" => {
          "Recorder Co" => {
            "RC-0001" => { "entry_ids" => [direct_entry.id, grouped_entry.id].sort, "disposition" => "reserve" }
          }
        }
      )
    end

    it "writes nothing when a company has an orphan" do
      orphan = recorder_spec_entry(locked: true)

      expect { described_class.write!(path: @recorder_spec_path, as_of: "2026-10-23") }
        .to raise_error(described_class::Error, /Recorder Co has orphans: entries #{orphan.id}/)
      expect(File).not_to exist(@recorder_spec_path)
    end

    it "writes nothing when an entry has two discarded non-draft owners" do
      contested_entry = recorder_spec_entry(locked: true)
      invoices = %w[RC-0005 RC-0006].map do |number|
        invoice = recorder_spec_sent_invoice(number)
        line = create(:invoice_line_item, invoice:, timesheet_entry: nil, rate: 100, quantity: 120)
        # Inserted without callbacks: two kept invoices on one entry is a legacy
        # state that invoice saves now refuse, so it is written directly.
        InvoiceLineItemTimeEntry.insert_all!([{ invoice_line_item_id: line.id, timesheet_entry_id: contested_entry.id }])
        invoice
      end
      invoices.each { |invoice| invoice.update_columns(discarded_at: Time.current) }

      expect { described_class.write!(path: @recorder_spec_path, as_of: "2026-10-23") }
        .to raise_error(described_class::Error, /Recorder Co has conflicts: entries #{contested_entry.id}/)
      expect(File).not_to exist(@recorder_spec_path)
    end

    it "writes nothing when an invoice links another company's entry" do
      other_company = create(:company)
      other_project = create(:project, client: create(:client, company: other_company), billable: true)
      other_user = create(:user, current_workspace_id: other_company.id)
      foreign_entry = create(:timesheet_entry, user: other_user, project: other_project, bill_status: "unbilled")
      line = create(:invoice_line_item, invoice: recorder_spec_sent_invoice("RC-0002"), rate: 100, quantity: 60)
      line.update_columns(timesheet_entry_id: foreign_entry.id)

      expect { described_class.write!(path: @recorder_spec_path, as_of: "2026-10-23") }
        .to raise_error(described_class::Error, /invoices linking entries of another company: entries #{foreign_entry.id}/)
      expect(File).not_to exist(@recorder_spec_path)
    end

    it "keeps the previous file when the run fails" do
      File.write(@recorder_spec_path, "previous\n")
      recorder_spec_entry(locked: true)

      expect { described_class.write!(path: @recorder_spec_path, as_of: "2026-10-23") }
        .to raise_error(described_class::Error)
      expect(File.read(@recorder_spec_path)).to eq("previous\n")
    end
  end
end

RSpec.describe TestDatabaseCleanup do
  # Both seeded test paths must share one store, or each would pay for its own
  # real seed load.
  it "returns the same seed capture store on every call in a process" do
    expect(described_class.seed_captures).to be_a(Timekeeping::SeedCapture::Store)
    expect(described_class.seed_captures).to be(described_class.seed_captures)
  end
end

RSpec.describe Timekeeping::SeedDispositionRecorder, :without_transaction do
  def recorder_store_spec_connection
    ActiveRecord::Base.connection
  end

  def recorder_store_spec_state
    connection = recorder_store_spec_connection
    tables = (connection.tables - described_class::METADATA_TABLES).sort
    digests = tables.index_with do |table|
      connection.select_value(
        "SELECT md5(coalesce(string_agg(t::text, E'\\n' ORDER BY t::text), '')) FROM #{connection.quote_table_name(table)} t"
      )
    end
    sequences = connection.select_values(<<~SQL).sort.to_h do |name|
      SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind = 'S' AND n.nspname = current_schema()
    SQL
      row = connection.select_one("SELECT last_value, is_called FROM #{connection.quote_table_name(name)}")
      [name, [row["last_value"].to_i, row["is_called"]]]
    end
    { digests:, sequences: }
  end

  it "with a store, a second load restores the first load's capture with the same ids and sequences, well under a minute" do
    as_of = TestDatabaseCleanup.seed_as_of
    store = Timekeeping::SeedCapture::Store.new
    expect(store.fetch(as_of)).to be_nil

    # The :without_transaction hook leaves the ownership row in place, which
    # the empty-table guard refuses.
    TestDatabaseCleanup.before_reset!
    DatabaseCleaner.clean_with :truncation, except: %w(ar_internal_metadata)
    described_class.load_fresh_seed!(as_of:, captures: store)
    expect(store.fetch(as_of)).to be_a(Timekeeping::SeedCapture)
    first_load = recorder_store_spec_state

    DatabaseCleaner.clean_with :truncation, except: %w(ar_internal_metadata)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    described_class.load_fresh_seed!(as_of:, captures: store)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    # "Reloading the two-tenant seed for a handoff example group takes well under a minute, either through bulk inserts in db/seeds.rb or by restoring a captured snapshot, and gives the same ids and sequence values as before."
    expect(recorder_store_spec_state).to eq(first_load)
    expect(elapsed).to be < 20
    expect(Company.pluck(:name)).to contain_exactly("Fork & Leaf Salads", "Copper Kettle Bakery")
  end
end

RSpec.describe Timekeeping::SeedDispositionRecorder do
  # A restore over existing rows would stack the seed on data that was never
  # the seed, and the ids would no longer be "the same ids and sequence
  # values as before".
  it "refuses a lone-user database before restoring a stored capture, and leaves that user unchanged" do
    # A stand-in that only records whether it was restored, so the guard's
    # order is observable.
    restored = []
    capture = Object.new
    capture.define_singleton_method(:restore!) { |**| restored << :restore }
    store = Timekeeping::SeedCapture::Store.new
    store.store("2026-10-23", capture)
    user = create(:user, email: "dana@forkandleaf.example", current_workspace: nil, first_name: "Existing")
    Company.delete_all
    before = user.reload.attributes.slice("first_name", "last_name", "encrypted_password", "current_workspace_id")

    expect { described_class.load_fresh_seed!(as_of: "2026-10-23", captures: store) }
      .to raise_error(described_class::Error, /users/)

    expect(restored).to be_empty
    expect(user.reload.attributes.slice("first_name", "last_name", "encrypted_password", "current_workspace_id"))
      .to eq(before)
    expect(User.count).to eq(1)
    expect(Company.count).to eq(0)
  end
end

RSpec.describe Timekeeping::SeedDispositionRecorder, :two_tenant_seed, :seeded_without_transaction do
  def failed_restore_spec_ids
    %w[companies invoices invoice_line_items].index_with do |table|
      connection = ActiveRecord::Base.connection
      connection.select_values("SELECT id FROM #{connection.quote_table_name(table)} ORDER BY id").map(&:to_i)
    end
  end

  def failed_restore_spec_sequence(table)
    connection = ActiveRecord::Base.connection
    name = connection.select_value("SELECT pg_get_serial_sequence(#{connection.quote(table)}, 'id')")
    connection.select_one("SELECT last_value, is_called FROM #{name}").to_h
  end

  # Acceptance: the reload "gives the same ids and sequence values as before".
  # PostgreSQL does not roll back setval, so a restore that moved a sequence
  # and then failed must not leave the fallback seed load on shifted ids.
  it "after a restore that moved sequences and then failed, falls back to a real load with the same ids and sequence values and replaces the capture" do
    as_of = TestDatabaseCleanup.seed_as_of
    user_ids = User.order(:id).pluck(:id, :email)
    entry_ids = TimesheetEntry.order(:id).pluck(:id)
    other_ids = failed_restore_spec_ids
    users_sequence = failed_restore_spec_sequence("users")
    entries_sequence = failed_restore_spec_sequence("timesheet_entries")

    broken = Object.new
    broken.define_singleton_method(:restore!) do |connection:|
      %w[users timesheet_entries].each do |table|
        name = connection.select_value("SELECT pg_get_serial_sequence(#{connection.quote(table)}, 'id')")
        connection.select_value("SELECT setval(#{connection.quote(name)}, 900000)")
      end
      raise Timekeeping::SeedCapture::RestoreError, "blob file missing"
    end
    store = Timekeeping::SeedCapture::Store.new
    store.store(as_of, broken)

    TestDatabaseCleanup.before_reset!
    DatabaseCleaner.clean_with :truncation, except: %w(ar_internal_metadata)
    described_class.load_fresh_seed!(as_of:, captures: store)

    expect(User.order(:id).pluck(:id, :email)).to eq(user_ids)
    expect(TimesheetEntry.order(:id).pluck(:id)).to eq(entry_ids)
    expect(failed_restore_spec_ids).to eq(other_ids)
    expect(failed_restore_spec_sequence("users")).to eq(users_sequence)
    expect(failed_restore_spec_sequence("timesheet_entries")).to eq(entries_sequence)
    expect(store.fetch(as_of)).to be_a(Timekeeping::SeedCapture)
  end
end

RSpec.describe Timekeeping::SeedDispositionRecorder, :two_tenant_seed, :seeded_without_transaction do
  # Seeded entries depend on as_of, so a copy taken at another as_of would
  # not give "the same ids and sequence values as before".
  it "does not restore a capture stored for a different as_of, and stores a real capture for the requested one" do
    as_of = TestDatabaseCleanup.seed_as_of
    entry_ids = TimesheetEntry.order(:id).pluck(:id)
    restored = []
    stale = Object.new
    stale.define_singleton_method(:restore!) { |**| restored << :restore }
    store = Timekeeping::SeedCapture::Store.new
    store.store("2000-01-01", stale)

    TestDatabaseCleanup.before_reset!
    DatabaseCleaner.clean_with :truncation, except: %w(ar_internal_metadata)
    described_class.load_fresh_seed!(as_of:, captures: store)

    expect(restored).to be_empty
    expect(TimesheetEntry.order(:id).pluck(:id)).to eq(entry_ids)
    expect(store.fetch(as_of)).to be_a(Timekeeping::SeedCapture)
    expect(store.fetch("2000-01-01")).to be(stale)
  end
end
