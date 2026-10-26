# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::Gateway, committed_data: true do
  it "makes a write wait while another transaction holds the ownership row for update" do
    company = create(:company)
    project = create(:project, billable: true, client: create(:client, company:))
    user = create(:user, current_workspace_id: company.id)
    create(:employment, company:, user:)
    context = Timekeeping::WriteContext.new(company:, actor: user, actor_kind: "user", request_id: "req-fence-wait")
    holder_pids = Queue.new
    writer_pids = Queue.new
    locked = Queue.new
    release = Queue.new

    holder = committed_data_thread(holder_pids) do
      ActiveRecord::Base.transaction do
        TimekeepingOwnership.lock("FOR UPDATE").find(TimekeepingOwnership::SINGLETON_ID)
        locked << true
        release.pop(timeout: 10)
      end
    end
    expect(locked.pop(timeout: 5)).to be(true)

    writer = committed_data_thread(writer_pids) do
      described_class.new(context:).create(
        user:, project:, attributes: { duration: 30, work_date: Date.current, note: "waited", bill_status: "unbilled" }
      )
    end

    begin
      blocked = blocked_by?(writer_pids.pop(timeout: 5), holder_pids.pop(timeout: 5))
      written_while_locked = TimesheetEntry.where(note: "waited").exists?
    ensure
      release << true
    end

    expect(blocked).to be(true), "the gateway write never waited on the ownership row lock"
    expect(written_while_locked).to be(false)
    holder.join(5)
    expect(writer.join(5)&.value).to be_persisted
    expect(TimesheetEntry.where(note: "waited", user_id: user.id)).to exist
  ensure
    release << true
    [holder, writer].compact.each { |thread| thread.join(5) }
  end
end
