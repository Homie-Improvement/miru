require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport do
  include PreparedReservationsSpecSupport

  before { prepare_local_ownership! }

  # Callers that pass no keywords, such as the concurrency spec, must keep the fixtures they get today.
  it "prepared_spec_entry without keywords builds a fresh user and project per entry with today's fixed values" do
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
    expect(first.user_id).not_to eq(second.user_id)
    expect(first.project_id).not_to eq(second.project_id)
    expect(prepared_spec_entry(company, bill_status: "billed").bill_status).to eq("billed")
  end
end

require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport do
  include PreparedReservationsSpecSupport

  before { prepare_local_ownership! }

  # "Give prepared_spec_entry optional user:, project: and id: keywords and use it, along with prepared_spec_request, in place of the copied *_entry and *_request helpers."
  # The tenant examples pass one user employed by two companies, so the entries differ only in company.
  it "prepared_spec_entry stores the user, project and id it is given" do
    company = create(:company)
    other_company = create(:company)
    shared_user = create(:user)
    project = create(:project, client: create(:client, company:), billable: true)
    other_project = create(:project, client: create(:client, company: other_company))

    own = prepared_spec_entry(company, user: shared_user, project:)
    foreign = prepared_spec_entry(other_company, user: shared_user, project: other_project)
    chosen = prepared_spec_entry(company, user: shared_user, project:, id: 424_242)

    expect(Timekeeping::LocalEntry.find(own.id).attributes.slice("company_id", "user_id", "project_id"))
      .to eq("company_id" => company.id, "user_id" => shared_user.id, "project_id" => project.id)
    expect(Timekeeping::LocalEntry.find(foreign.id).attributes.slice("company_id", "user_id", "project_id"))
      .to eq("company_id" => other_company.id, "user_id" => shared_user.id, "project_id" => other_project.id)
    expect(chosen.id).to eq(424_242)
    expect(Timekeeping::LocalEntry.find(424_242).user_id).to eq(shared_user.id)
  end
end

require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport do
  include PreparedReservationsSpecSupport

  # "Add prepared_spec_projected_entry(company) to the support module and use it in place of prepared_save_spec_entry, the inline Array.new builder and prepared_e2e_entry."
  # Invoice lines point at the timesheet row while the adapter reads the prepared entry, so both share one id.
  it "prepared_spec_projected_entry returns the timesheet row with a prepared entry under the same id" do
    company = create(:company)

    row = prepared_spec_projected_entry(company)

    expect(row).to be_a(TimesheetEntry)
    expect(row.bill_status).to eq("unbilled")
    expect(row.user.current_workspace_id).to eq(company.id)
    expect(row.project.billable).to be(true)
    expect(row.project.client.company_id).to eq(company.id)
    prepared = Timekeeping::LocalEntry.find(row.id)
    expect(prepared.company_id).to eq(company.id)
    expect(prepared.user_id).to eq(row.user_id)
    expect(prepared.project_id).to eq(row.project_id)
    expect(prepared.work_date).to eq(row.work_date)
    expect(prepared.duration).to eq(row.duration)
    expect(prepared.bill_status).to eq("unbilled")
  end
end

require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport do
  include PreparedReservationsSpecSupport

  # The discard example records both entries with one user on one project.
  it "prepared_spec_projected_entry shares the user and project it is given across entries" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    project = create(:project, client: create(:client, company:), billable: true)

    rows = Array.new(2) { prepared_spec_projected_entry(company, user:, project:) }

    expect(rows.map(&:id).uniq.size).to eq(2)
    expect(rows.map(&:user_id)).to eq([user.id, user.id])
    expect(rows.map(&:project_id)).to eq([project.id, project.id])
    expect(Timekeeping::LocalEntry.where(id: rows.map(&:id)).order(:id).pluck(:user_id, :project_id))
      .to eq([[user.id, project.id], [user.id, project.id]])
  end
end

require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport do
  include PreparedReservationsSpecSupport

  before { prepare_local_ownership! }

  # The admit example sends an invoice id that names no stored invoice, so only the id is read.
  it "prepared_spec_request carries the company, the invoice id, the entries and the current generation" do
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
  end
end

require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport do
  include PreparedReservationsSpecSupport

  # Callers that pass no keywords, such as the concurrency spec, must keep today's fixtures.
  it "prepared_spec_entry without keywords builds a fresh user and project per entry in the given company" do
    company = create(:company)

    first = prepared_spec_entry(company)
    second = prepared_spec_entry(company)

    expect([first.company_id, second.company_id]).to eq([company.id, company.id])
    expect(first.user_id).not_to eq(second.user_id)
    expect(first.project_id).not_to eq(second.project_id)
    expect(Project.find(first.project_id).client.company_id).to eq(company.id)
    expect([first.work_date, first.duration, first.bill_status]).to eq([Date.current, 60.0, "unbilled"])
  end
end

require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport do
  include PreparedReservationsSpecSupport

  # "Give prepared_spec_entry optional user:, project: and id: keywords and use it, along with prepared_spec_request, in place of the copied *_entry and *_request helpers."
  # The tenant examples rely on one user employed by both companies, so only the company check can refuse the foreign entry.
  it "prepared_spec_entry with one shared user builds entries that differ only in their company" do
    own_company = create(:company)
    foreign_company = create(:company)
    user = create(:user)
    own_project = create(:project, client: create(:client, company: own_company))
    foreign_project = create(:project, client: create(:client, company: foreign_company))

    own_entry = prepared_spec_entry(own_company, user:, project: own_project)
    foreign_entry = prepared_spec_entry(foreign_company, user:, project: foreign_project)

    expect([own_entry.user_id, foreign_entry.user_id]).to eq([user.id, user.id])
    expect([own_entry.project_id, foreign_entry.project_id]).to eq([own_project.id, foreign_project.id])
    expect([own_entry.company_id, foreign_entry.company_id]).to eq([own_company.id, foreign_company.id])
    expect(Timekeeping::LocalEntry.where(company_id: own_company.id).pluck(:id)).to eq([own_entry.id])
  end
end

require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport do
  include PreparedReservationsSpecSupport

  # The line-claim examples copy a timesheet entry into the prepared table under the same id.
  it "prepared_spec_entry with id: stores the entry under that id" do
    company = create(:company)
    project = create(:project, client: create(:client, company:), billable: true)
    user = create(:user, current_workspace_id: company.id)
    row = create(:timesheet_entry, user:, project:, bill_status: "unbilled")

    entry = prepared_spec_entry(company, user:, project:, id: row.id)

    expect(entry.id).to eq(row.id)
    expect(Timekeeping::LocalEntry.find(row.id).company_id).to eq(company.id)
    expect([entry.user_id, entry.project_id]).to eq([user.id, project.id])
  end
end

require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport do
  include PreparedReservationsSpecSupport

  # "Add prepared_spec_projected_entry(company) to the support module and use it in place of prepared_save_spec_entry, the inline Array.new builder and prepared_e2e_entry."
  it "prepared_spec_projected_entry returns the timesheet row with a matching prepared entry under the same id" do
    company = create(:company)

    row = prepared_spec_projected_entry(company)

    expect(row).to be_a(TimesheetEntry)
    expect(row.bill_status).to eq("unbilled")
    expect(Project.find(row.project_id).client.company_id).to eq(company.id)
    expect(Project.find(row.project_id).billable).to be(true)
    expect(User.find(row.user_id).current_workspace_id).to eq(company.id)
    prepared = Timekeeping::LocalEntry.find(row.id)
    expect([prepared.company_id, prepared.user_id, prepared.project_id]).to eq([company.id, row.user_id, row.project_id])
    expect([prepared.work_date, prepared.duration, prepared.bill_status]).to eq([row.work_date, row.duration, "unbilled"])
  end
end

require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport do
  include PreparedReservationsSpecSupport

  # The discard example shares one user and project across its two entries.
  it "prepared_spec_projected_entry with a shared user and project builds both entries on them" do
    company = create(:company)
    project = create(:project, client: create(:client, company:), billable: true)
    user = create(:user, current_workspace_id: company.id)

    rows = Array.new(2) { prepared_spec_projected_entry(company, user:, project:) }

    expect(rows.map(&:id).uniq.size).to eq(2)
    expect(rows.map { |row| [row.user_id, row.project_id] }).to eq([[user.id, project.id]] * 2)
    prepared = Timekeeping::LocalEntry.where(id: rows.map(&:id)).order(:id)
    expect(prepared.map { |entry| [entry.company_id, entry.user_id, entry.project_id] })
      .to eq([[company.id, user.id, project.id]] * 2)
  end
end

require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport do
  include PreparedReservationsSpecSupport

  # The admit example names invoice id 901 with no stored invoice; the cross-company example sends
  # another company's id with the owning invoice. Both go through this one builder.
  it "prepared_spec_request carries the given company and an unsaved invoice id as the admit example sends" do
    company = create(:company)
    operation_id = SecureRandom.uuid

    request = prepared_spec_request(company, Invoice.new(id: 901), [11, 12], operation_id:)

    expect(request).to be_a(Invoices::ReservationRequest)
    expect(request.company_id).to eq(company.id)
    expect(request.invoice_id).to eq(901)
    expect(request.entries).to eq([11, 12])
    expect(request.operation_id).to eq(operation_id)
    expect(request.disposition).to eq("active")
    expect(Invoice.exists?(901)).to be(false)
  end
end

# frozen_string_literal: true
require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport do
  include PreparedReservationsSpecSupport

  before { prepare_local_ownership! }

  # "Give prepared_spec_entry optional user:, project: and id: keywords"
  # The tenant examples pass one user employed by two companies; if the keyword
  # were ignored, the foreign entry would differ in its user as well as its company.
  it "prepared_spec_entry builds the entry for a given user and project, and a fresh user and project without them" do
    company = create(:company)
    shared_user = create(:user)
    shared_project = create(:project, client: create(:client, company:), billable: true)

    first = prepared_spec_entry(company, user: shared_user, project: shared_project)
    second = prepared_spec_entry(company, user: shared_user, project: shared_project)
    fresh = prepared_spec_entry(company)

    expect([first.user_id, second.user_id]).to eq([shared_user.id, shared_user.id])
    expect([first.project_id, second.project_id]).to eq([shared_project.id, shared_project.id])
    expect([first.company_id, second.company_id, fresh.company_id]).to all(eq(company.id))
    expect(fresh.user_id).not_to eq(shared_user.id)
    expect(fresh.project_id).not_to eq(shared_project.id)
    expect(Project.find(fresh.project_id).client.company_id).to eq(company.id)
    expect(fresh.work_date).to eq(Date.current)
    expect(fresh.duration).to eq(60.0)
    expect(fresh.bill_status).to eq("unbilled")
  end
end

# frozen_string_literal: true
require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport do
  include PreparedReservationsSpecSupport

  before { prepare_local_ownership! }

  # "Give prepared_spec_entry optional user:, project: and id: keywords"
  # The line-claim examples copy a timesheet entry into the prepared table under its own id.
  it "prepared_spec_entry stores the entry under a given id" do
    company = create(:company)

    entry = prepared_spec_entry(company, id: 424_242)

    expect(entry.id).to eq(424_242)
    expect(Timekeeping::LocalEntry.where(id: 424_242, company_id: company.id).count).to eq(1)
  end
end

# frozen_string_literal: true
require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport do
  include PreparedReservationsSpecSupport

  before { prepare_local_ownership! }

  # "Add prepared_spec_projected_entry(company) to the support module and use it in place of
  # prepared_save_spec_entry, the inline Array.new builder and prepared_e2e_entry."
  # The inline Array.new builder made two entries for one shared user and project.
  it "prepared_spec_projected_entry shares a given user and project across entries and builds distinct ones without them" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    project = create(:project, client: create(:client, company:), billable: true)

    shared = Array.new(2) { prepared_spec_projected_entry(company, user:, project:) }
    separate = Array.new(2) { prepared_spec_projected_entry(company) }

    expect(shared.map(&:user_id)).to eq([user.id, user.id])
    expect(shared.map(&:project_id)).to eq([project.id, project.id])
    expect(Timekeeping::LocalEntry.where(id: shared.map(&:id)).pluck(:user_id, :project_id).uniq)
      .to eq([[user.id, project.id]])
    expect(shared.map(&:id).uniq.size).to eq(2)
    expect(separate.map(&:user_id).uniq.size).to eq(2)
    expect(separate.map(&:project_id).uniq.size).to eq(2)
  end
end

require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport, "entry builders in the prepared reservations specs" do
  # "The prepared reservations specs build entries and requests only through PreparedReservationsSpecSupport helpers
  # (prepared_spec_entry with user:/project:/id: keywords, prepared_spec_request, prepared_spec_projected_entry), with
  # no locally copied *_entry or *_request helpers left."
  it "prepared reservations specs create no prepared entry outside the support helpers" do
    paths = %w[
      spec/services/invoices/prepared_reservations_spec.rb
      spec/services/invoices/prepared_reservations_save_spec.rb
    ]

    offenders = paths.select { |path| Rails.root.join(path).read.include?("LocalEntry.create!") }

    expect(offenders).to eq([])
  end
end

require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport, "request builders in the prepared reservations specs" do
  # "The prepared reservations specs build entries and requests only through PreparedReservationsSpecSupport helpers
  # (prepared_spec_entry with user:/project:/id: keywords, prepared_spec_request, prepared_spec_projected_entry), with
  # no locally copied *_entry or *_request helpers left."
  it "prepared reservations specs build no reservation request outside prepared_spec_request" do
    paths = %w[
      spec/services/invoices/prepared_reservations_spec.rb
      spec/services/invoices/prepared_reservations_save_spec.rb
    ]

    offenders = paths.select { |path| Rails.root.join(path).read.include?("ReservationRequest.new") }

    expect(offenders).to eq([])
  end
end

require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport, "local helpers in the prepared reservations specs" do
  # "The prepared reservations specs build entries and requests only through PreparedReservationsSpecSupport helpers
  # (prepared_spec_entry with user:/project:/id: keywords, prepared_spec_request, prepared_spec_projected_entry), with
  # no locally copied *_entry or *_request helpers left."
  it "prepared reservations specs define no local entry or request helper of their own" do
    paths = %w[
      spec/services/invoices/prepared_reservations_spec.rb
      spec/services/invoices/prepared_reservations_save_spec.rb
    ]

    local_helpers = paths.flat_map do |path|
      Rails.root.join(path).read.scan(/^\s*def (\w+_(?:entry|request|copy))\b/).flatten
    end

    expect(local_helpers).to eq([])
  end
end

require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport, "entry id keyword" do
  include PreparedReservationsSpecSupport

  # "Give prepared_spec_entry optional user:, project: and id: keywords"
  # The line-claim examples copy a timesheet row into the prepared table, so an
  # id that is dropped or replaced would leave the line pointing at no entry.
  it "prepared_spec_entry given an id stores the prepared entry under exactly that id in the given company" do
    company = create(:company)
    row = create(:timesheet_entry, project: create(:project, client: create(:client, company:)))

    entry = prepared_spec_entry(company, id: row.id)

    expect(entry.id).to eq(row.id)
    stored = Timekeeping::LocalEntry.find_by!(company_id: company.id, id: row.id)
    expect(stored.bill_status).to eq("unbilled")
  end
end

require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport, "entry id default" do
  include PreparedReservationsSpecSupport

  # A default that sent a fixed or nil id to the insert would make the second
  # entry collide with the first or fail, breaking every caller that builds two.
  it "prepared_spec_entry without an id lets the database assign a distinct id to each entry" do
    company = create(:company)

    first = prepared_spec_entry(company)
    second = prepared_spec_entry(company)

    expect([first.id, second.id]).to all(be_present)
    expect(first.id).not_to eq(second.id)
    expect(first.user_id).not_to eq(second.user_id)
    expect(first.project_id).not_to eq(second.project_id)
  end
end

require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport, "shared user keyword" do
  include PreparedReservationsSpecSupport

  # The tenant examples need the foreign entry to differ from the own entry
  # only in its company. If the helper ignored user: and made a fresh user,
  # a user check could refuse the foreign entry and hide a missing company check.
  it "prepared_spec_entry given one shared user in two companies builds entries that differ only in company and project" do
    own_company = create(:company)
    foreign_company = create(:company)
    user = create(:user)
    own_project = create(:project, client: create(:client, company: own_company))
    foreign_project = create(:project, client: create(:client, company: foreign_company))

    own_entry = prepared_spec_entry(own_company, user:, project: own_project)
    foreign_entry = prepared_spec_entry(foreign_company, user:, project: foreign_project)

    expect([own_entry.user_id, foreign_entry.user_id]).to eq([user.id, user.id])
    expect([own_entry.company_id, foreign_entry.company_id]).to eq([own_company.id, foreign_company.id])
    expect([own_entry.project_id, foreign_entry.project_id]).to eq([own_project.id, foreign_project.id])
  end
end

require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport, "projected entry" do
  include PreparedReservationsSpecSupport

  # "Add prepared_spec_projected_entry(company) to the support module and use it in place of prepared_save_spec_entry, the inline Array.new builder and prepared_e2e_entry."
  # Invoice lines point at the timesheet row while the adapter reads the
  # prepared table, so each row must have a prepared copy under the same id,
  # and two calls sharing a user and project must not merge into one entry.
  it "prepared_spec_projected_entry called twice with a shared user and project keeps each prepared entry under its own timesheet row id" do
    company = create(:company)
    user = create(:user, current_workspace_id: company.id)
    project = create(:project, client: create(:client, company:), billable: true)

    rows = Array.new(2) { prepared_spec_projected_entry(company, user:, project:) }

    expect(rows).to all(be_a(TimesheetEntry))
    expect(rows.map(&:id).uniq.size).to eq(2)
    rows.each do |row|
      prepared = Timekeeping::LocalEntry.find_by!(company_id: company.id, id: row.id)
      expect([prepared.user_id, prepared.project_id]).to eq([user.id, project.id])
      expect([row.user_id, row.project_id]).to eq([user.id, project.id])
      expect(prepared.work_date).to eq(row.work_date)
      expect(prepared.duration.to_f).to eq(row.duration.to_f)
      expect(prepared.bill_status).to eq("unbilled")
    end
  end
end

require "rails_helper"

RSpec.describe PreparedReservationsSpecSupport, "request builder" do
  include PreparedReservationsSpecSupport

  # The admit example sends an invoice id with no stored invoice, and the
  # cross-company example sends the intruding company with the owning invoice.
  # A builder that looked the invoice up or took the company from it would
  # turn both into requests the examples do not mean to send.
  it "prepared_spec_request built for another company with an unsaved invoice id carries that company and invoice id unchanged" do
    intruding_company = create(:company)
    operation_id = SecureRandom.uuid

    request = prepared_spec_request(intruding_company, Invoice.new(id: 901), [11, 12], operation_id:)

    expect(request).to be_a(Invoices::ReservationRequest)
    expect(request.company_id).to eq(intruding_company.id)
    expect(request.invoice_id).to eq(901)
    expect(request.entries).to eq([11, 12])
    expect(request.operation_id).to eq(operation_id)
    expect(request.disposition).to eq("active")
    expect(request.generation).to eq(TimekeepingOwnership.current.generation)
  end
end
