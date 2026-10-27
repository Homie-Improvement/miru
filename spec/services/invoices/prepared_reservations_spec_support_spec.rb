# frozen_string_literal: true

require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport do
  include PreparedReservationsSpecSupport

  before { prepare_local_ownership! }

  describe "prepared_spec_entry" do
    # Callers that pass no keywords, such as the concurrency spec, must keep the fixtures they get today.
    it "without keywords builds each entry with its own id, user and project and today's fixed values" do
      company = create(:company)

      first = prepared_spec_entry(company)
      second = prepared_spec_entry(company)

      [first, second].each do |entry|
        stored = Timekeeping::LocalEntry.find(entry.id)
        expect(stored.company_id).to eq(company.id)
        expect(stored.work_date).to eq(Date.current)
        expect(stored.duration).to eq(60.0)
        expect(stored.bill_status).to eq("unbilled")
        expect(Project.find(stored.project_id).client.company_id).to eq(company.id)
      end
      expect([first.id, second.id]).to all(be_present)
      expect(first.id).not_to eq(second.id)
      expect(first.user_id).not_to eq(second.user_id)
      expect(first.project_id).not_to eq(second.project_id)
      expect(prepared_spec_entry(company, bill_status: "billed").bill_status).to eq("billed")
    end

    # The tenant examples need the foreign entry to differ from the own entry
    # only in its company. If the helper ignored user: and made a fresh user,
    # a user check could refuse the foreign entry and hide a missing company check.
    it "given one shared user in two companies builds entries that differ only in company and project" do
      own_company = create(:company)
      foreign_company = create(:company)
      user = create(:user)
      own_project = create(:project, client: create(:client, company: own_company), billable: true)
      foreign_project = create(:project, client: create(:client, company: foreign_company))

      own_entry = prepared_spec_entry(own_company, user:, project: own_project)
      foreign_entry = prepared_spec_entry(foreign_company, user:, project: foreign_project)
      fresh = prepared_spec_entry(own_company)

      expect(Timekeeping::LocalEntry.find(own_entry.id).attributes.slice("company_id", "user_id", "project_id"))
        .to eq("company_id" => own_company.id, "user_id" => user.id, "project_id" => own_project.id)
      expect(Timekeeping::LocalEntry.find(foreign_entry.id).attributes.slice("company_id", "user_id", "project_id"))
        .to eq("company_id" => foreign_company.id, "user_id" => user.id, "project_id" => foreign_project.id)
      expect(fresh.user_id).not_to eq(user.id)
      expect(fresh.project_id).not_to eq(own_project.id)
      expect(Timekeeping::LocalEntry.where(company_id: foreign_company.id).pluck(:id)).to eq([foreign_entry.id])
    end

    # The projected entry copies its timesheet row's date and duration through
    # these keywords, so values that differ from the defaults must be stored as given.
    it "given a work_date and duration stores those values in place of the defaults" do
      company = create(:company)

      entry = prepared_spec_entry(company, work_date: Date.new(2026, 3, 2), duration: 480.0)

      stored = Timekeeping::LocalEntry.find(entry.id)
      expect([stored.work_date, stored.duration]).to eq([Date.new(2026, 3, 2), 480.0])
    end

    # The line-claim examples copy a timesheet row into the prepared table, so an
    # id that is dropped or replaced would leave the line pointing at no entry.
    it "given an id stores the entry under exactly that id in the given company" do
      company = create(:company)
      user = create(:user, current_workspace_id: company.id)
      project = create(:project, client: create(:client, company:), billable: true)
      row = create(:timesheet_entry, user:, project:, bill_status: "unbilled")

      copied = prepared_spec_entry(company, user:, project:, id: row.id)
      chosen = prepared_spec_entry(company, user:, project:, id: 424_242)

      expect(copied.id).to eq(row.id)
      expect(chosen.id).to eq(424_242)
      expect(Timekeeping::LocalEntry.where(company_id: company.id, id: [row.id, 424_242]).pluck(:user_id, :project_id))
        .to eq([[user.id, project.id]] * 2)
    end
  end

  describe "prepared_spec_projected_entry" do
    # Invoice lines point at the timesheet row while the adapter reads the
    # prepared entries table, so both must exist under one id with matching fields.
    it "returns the timesheet row with a matching prepared entry under the same id" do
      company = create(:company)

      row = prepared_spec_projected_entry(company)

      expect(row).to be_a(TimesheetEntry)
      expect(row.bill_status).to eq("unbilled")
      expect(User.find(row.user_id).current_workspace_id).to eq(company.id)
      project = Project.find(row.project_id)
      expect(project.billable).to be(true)
      expect(project.client.company_id).to eq(company.id)
      prepared = Timekeeping::LocalEntry.find(row.id)
      expect([prepared.company_id, prepared.user_id, prepared.project_id]).to eq([company.id, row.user_id, row.project_id])
      expect([prepared.work_date, prepared.duration, prepared.bill_status]).to eq([row.work_date, row.duration, "unbilled"])
    end

    # The discard example records both entries with one user on one project;
    # two calls sharing them must still make two entries.
    it "shares a given user and project across entries and builds distinct ones without them" do
      company = create(:company)
      user = create(:user, current_workspace_id: company.id)
      project = create(:project, client: create(:client, company:), billable: true)

      shared = Array.new(2) { prepared_spec_projected_entry(company, user:, project:) }
      separate = Array.new(2) { prepared_spec_projected_entry(company) }

      expect(shared.map(&:id).uniq.size).to eq(2)
      expect(shared.map { |row| [row.user_id, row.project_id] }).to eq([[user.id, project.id]] * 2)
      expect(Timekeeping::LocalEntry.where(id: shared.map(&:id)).order(:id).pluck(:company_id, :user_id, :project_id))
        .to eq([[company.id, user.id, project.id]] * 2)
      expect(separate.map(&:user_id).uniq.size).to eq(2)
      expect(separate.map(&:project_id).uniq.size).to eq(2)
    end
  end

  describe "prepared_spec_request" do
    # The admit example sends an invoice id with no stored invoice, and the
    # cross-company example sends the intruding company with the owning invoice.
    # A builder that looked the invoice up or took the company from it would
    # turn both into requests the examples do not mean to send.
    it "carries the given company, an unsaved invoice's id, the entries and the current generation" do
      company = create(:company)
      operation_id = SecureRandom.uuid

      request = prepared_spec_request(company, Invoice.new(id: 901), [11, 12], disposition: "retained", operation_id:)

      expect(request).to be_a(Invoices::ReservationRequest)
      expect(request.company_id).to eq(company.id)
      expect(request.invoice_id).to eq(901)
      expect(request.entries).to eq([11, 12])
      expect(request.disposition).to eq("retained")
      expect(request.operation_id).to eq(operation_id)
      expect(request.generation).to eq(TimekeepingOwnership.current.generation)
      expect(prepared_spec_request(company, Invoice.new(id: 901), []).disposition).to eq("active")
      expect(Invoice.exists?(901)).to be(false)
    end
  end

  # "The prepared reservations specs build entries and requests only through PreparedReservationsSpecSupport helpers
  # (prepared_spec_entry with user:/project:/id: keywords, prepared_spec_request, prepared_spec_projected_entry), with
  # no locally copied *_entry or *_request helpers left."
  describe "use in the prepared reservations specs" do
    let(:prepared_support_user_sources) do
      %w[
        spec/services/invoices/prepared_reservations_spec.rb
        spec/services/invoices/prepared_reservations_save_spec.rb
      ].index_with { |path| Rails.root.join(path).read }
    end

    it "creates no prepared entry outside the support helpers" do
      offenders = prepared_support_user_sources.select { |_path, source| source.include?("LocalEntry.create!") }.keys

      expect(offenders).to eq([])
    end

    it "builds no reservation request outside prepared_spec_request" do
      offenders = prepared_support_user_sources.select { |_path, source| source.include?("ReservationRequest.new") }.keys

      expect(offenders).to eq([])
    end

    it "defines no local entry or request helper of its own" do
      local_helpers = prepared_support_user_sources.values.flat_map do |source|
        source.scan(/^\s*def (\w+_(?:entry|request|copy))\b/).flatten
      end

      expect(local_helpers).to eq([])
    end
  end
end
