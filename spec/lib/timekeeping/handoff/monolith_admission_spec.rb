# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe Timekeeping::Handoff::MonolithAdmission do
  context "more tests 10" do
    before { TimekeepingOwnership.ensure_initial! }

    it "admit refuses a malformed generation and keeps the monolith fenced" do
      adapter = described_class.new(lock_timeout: 0.3.seconds)
      adapter.fence_admission

      [nil, 0, -1, "1", 1.0].each do |bad_generation|
        expect { adapter.admit(generation: bad_generation) }.to raise_error(ArgumentError)
      end

      # A refused admit must not reopen the monolith: it fails closed, not open.
      expect(TimekeepingOwnership.current.admission_fenced_at).not_to be_nil
      expect(TimekeepingOwnership.current.admission_closed?).to be(true)
    end
  end

  context "more tests 11" do
    before { TimekeepingOwnership.ensure_initial! }

    it "fence_admission raises when the ownership row is missing and never creates it" do
      TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).delete_all

      expect { described_class.new(lock_timeout: 0.3.seconds).fence_admission }
        .to raise_error(ActiveRecord::RecordNotFound)
      expect(TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID)).not_to exist
    end
  end

  context "more tests 12" do
    before { TimekeepingOwnership.ensure_initial! }

    it "after fence_admission a billing write is refused with OwnershipMoving and commits nothing" do
      described_class.new(lock_timeout: 0.3.seconds).fence_admission
      ownership = TimekeepingOwnership.current
      expect(ownership.handoff_step).to be_nil

      block_ran = false
      # "Then no writer can commit after `fence_admission` returns."
      expect { Timekeeping::BillingFence.transaction { block_ran = true } }
        .to raise_error(Timekeeping::BillingFence::OwnershipMoving)
      expect(block_ran).to be(false)
    end
  end

  context "more tests 13" do
    before { TimekeepingOwnership.ensure_initial! }

    it "admit clears only the fence mark and leaves ownership columns unchanged" do
      adapter = described_class.new(lock_timeout: 0.3.seconds)
      adapter.fence_admission
      before_admit = TimekeepingOwnership.current.attributes.slice("generation", "handoff_step", "owner", "monolith_store")

      adapter.admit(generation: before_admit.fetch("generation"))

      after_admit = TimekeepingOwnership.current
      expect(after_admit.admission_fenced_at).to be_nil
      expect(after_admit.attributes.slice("generation", "handoff_step", "owner", "monolith_store")).to eq(before_admit)
      expect(adapter.enforces_fence?).to be(true)
    end
  end

  context "more tests 14", "committed fence mark", committed_data: true do
    it "fence_admission commits the admission_fenced_at mark so another connection sees it once the call returns" do
      expect(TimekeepingOwnership.current.admission_fenced_at).to be_nil

      described_class.new(lock_timeout: 0.3.seconds).fence_admission

      # "Then no writer can commit after `fence_admission` returns." Writers run on other
      # connections, so the mark must already be committed when the call returns.
      seen = nil
      reader = committed_data_thread do
        seen = TimekeepingOwnership.find(TimekeepingOwnership::SINGLETON_ID).admission_fenced_at
      end
      reader.join(5) || reader.kill.join

      expect(seen).to be_present
      ownership = TimekeepingOwnership.current
      expect(ownership.admission_closed?).to be(true)
      expect(ownership.handoff_step).to be_nil
      expect(ownership.generation).to eq(1)
    end
  end

  context "more tests 15", "fence lock timeout", committed_data: true do
    it "a holder kept past the lock timeout makes fence_admission raise and leaves no mark or lock_timeout behind" do
      connection = ActiveRecord::Base.connection
      lock_timeout_before = connection.select_value("SHOW lock_timeout")
      held = Queue.new
      release = Queue.new
      holder = committed_data_thread do
        TimekeepingOwnership.transaction do
          TimekeepingOwnership.lock("FOR SHARE").find(TimekeepingOwnership::SINGLETON_ID)
          held << true
          release.pop
        end
      end

      begin
        expect(held.pop(timeout: 5)).to be(true)
        # "A holder kept past the lock timeout makes `fence_admission` raise and leaves no mark."
        expect do
          described_class.new(lock_timeout: 0.3.seconds).fence_admission
        end.to raise_error(ActiveRecord::LockWaitTimeout)
      ensure
        release << true
        holder.kill unless holder.join(5)
        holder.join
      end

      expect(TimekeepingOwnership.current.admission_fenced_at).to be_nil
      expect(TimekeepingOwnership.current.admission_closed?).to be(false)
      expect(connection.select_value("SHOW lock_timeout")).to eq(lock_timeout_before)
    end
  end

  context "more tests 16", "repeated fence" do
    it "fence_admission retried on a fenced row keeps it fenced and leaves the other ownership columns unchanged" do
      adapter = described_class.new(lock_timeout: 0.3.seconds)
      kept_columns = %w[generation handoff_step owner monolith_store final_outbox_position legacy_retired_at]
      before = TimekeepingOwnership.current.attributes.slice(*kept_columns)

      adapter.fence_admission
      expect { adapter.fence_admission }.not_to raise_error

      ownership = TimekeepingOwnership.current
      expect(ownership.admission_fenced_at).to be_present
      expect(ownership.admission_closed?).to be(true)
      expect(ownership.attributes.slice(*kept_columns)).to eq(before)
    end
  end

  context "more tests 17", "missing ownership row" do
    it "fence_admission on a missing ownership row raises and never creates the row" do
      TimekeepingOwnership.delete_all

      # A zero-row update must not be reported as a fence in place.
      expect do
        described_class.new(lock_timeout: 0.3.seconds).fence_admission
      end.to raise_error(ActiveRecord::RecordNotFound)
      expect(TimekeepingOwnership.count).to eq(0)
    end
  end

  context "more tests 18", "admit clears the mark" do
    it "admit clears the fence mark, a repeated admit is harmless, and no other ownership column changes" do
      adapter = described_class.new(lock_timeout: 0.3.seconds)
      kept_columns = %w[generation handoff_step owner monolith_store final_outbox_position legacy_retired_at]
      before = TimekeepingOwnership.current.attributes.slice(*kept_columns)
      adapter.fence_admission
      expect(TimekeepingOwnership.current.admission_closed?).to be(true)

      # "`admit(generation:)` clears `admission_fenced_at`."
      adapter.admit(generation: 1)
      ownership = TimekeepingOwnership.current
      expect(ownership.admission_fenced_at).to be_nil
      expect(ownership.admission_closed?).to be(false)

      # A rollback admits a monolith that was never fenced, and an abort may admit again.
      expect { adapter.admit(generation: 1) }.not_to raise_error
      after = TimekeepingOwnership.current
      expect(after.admission_fenced_at).to be_nil
      expect(after.attributes.slice(*kept_columns)).to eq(before)
    end
  end

  context "more tests 19", "close admission lifts the mark", committed_data: true do
    it "close_admission clears admission_fenced_at in the same update that sets handoff_step" do
      store = Object.new
      owners = TimekeepingHandoffFakes.owners(
        timekeeping: store, timekeeping_admission: TimekeepingHandoffFakes::RecordingAdmission.new,
        monolith_admission: described_class.new(lock_timeout: 0.3.seconds), monolith_store: store,
        settle: nil, relay: false
      )
      observer = TimekeepingHandoffHooks::Interrupt.new(at: :after_close_admission)

      ownership_updates = []
      capture = lambda do |_name, _start, _finish, _id, payload|
        sql = payload[:sql].to_s
        ownership_updates << sql if sql.match?(/\AUPDATE\s+"?timekeeping_ownership"?/i)
      end

      Dir.mktmpdir do |report_root|
        ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
          expect do
            Timekeeping::Handoff::Runner.run(direction: :cutover, owners:, observer:, report_root:,
                                             close_admission_lock_timeout: 0.3.seconds)
          end.to raise_error(TimekeepingHandoffHooks::Interrupted)
        end
      end

      ownership = TimekeepingOwnership.current
      expect(ownership.handoff_step).to eq("close_admission")
      expect(ownership.admission_fenced_at).to be_nil

      # "In `Runner#close_admission`, clear `admission_fenced_at` in the same `update_all` that sets `handoff_step`."
      # The fence writes the mark first; the next update must both set the step and clear the mark.
      fence_index = ownership_updates.index { |sql| sql.include?("admission_fenced_at") && !sql.include?("handoff_step") }
      expect(fence_index).not_to be_nil
      later_updates = ownership_updates.drop(fence_index + 1)
      closing = later_updates.select { |sql| sql.include?("handoff_step") }
      expect(closing.size).to eq(1)
      expect(closing.first).to include("admission_fenced_at")
      expect(later_updates.take_while { |sql| !sql.include?("handoff_step") })
        .to all(satisfy { |sql| !sql.include?("admission_fenced_at") })
    end
  end

  context "more tests 20", committed_data: true do
    # "`fence_admission` waits on a FOR SHARE holder, proven with `blocked_by?` from spec/support/committed_data.rb, never with sleeps."
    it "fence_admission waits for a FOR SHARE holder of the ownership row and sets admission_fenced_at once it is released" do
      backend_pids = Queue.new
      held = Queue.new
      release = Queue.new
      holder = committed_data_thread(backend_pids) do
        TimekeepingOwnership.transaction do
          TimekeepingOwnership.lock("FOR SHARE").find(TimekeepingOwnership::SINGLETON_ID)
          held << true
          release.pop
        end
      end
      expect(held.pop(timeout: 5)).to be(true)
      holder_pid = backend_pids.pop

      fence_error = nil
      fencer = committed_data_thread(backend_pids) do
        described_class.new(lock_timeout: 10.seconds).fence_admission
      rescue StandardError => error
        fence_error = error
      end
      fencer_pid = backend_pids.pop(timeout: 5)

      begin
        expect(blocked_by?(fencer_pid, holder_pid, within: 3)).to be(true)
        expect(TimekeepingOwnership.current.admission_fenced_at).to be_nil
      ensure
        release << true
        [holder, fencer].each do |thread|
          thread.kill unless thread.join(5)
          thread.join
        end
      end

      expect(fence_error).to be_nil
      expect(TimekeepingOwnership.current.admission_fenced_at).not_to be_nil
    end
  end

  context "more tests 21", committed_data: true do
    # "A holder kept past the lock timeout makes `fence_admission` raise and leaves no mark."
    it "fence_admission raises LockWaitTimeout past its lock timeout, leaves no mark and restores lock_timeout" do
      held = Queue.new
      release = Queue.new
      holder = committed_data_thread do
        TimekeepingOwnership.transaction do
          TimekeepingOwnership.lock("FOR SHARE").find(TimekeepingOwnership::SINGLETON_ID)
          held << true
          release.pop
        end
      end

      connection = ActiveRecord::Base.connection
      default_lock_timeout = connection.select_value("SHOW lock_timeout")
      begin
        expect(held.pop(timeout: 5)).to be(true)
        expect do
          described_class.new(lock_timeout: 0.3.seconds).fence_admission
        end.to raise_error(ActiveRecord::LockWaitTimeout)
        expect(connection.select_value("SHOW lock_timeout")).to eq(default_lock_timeout)
      ensure
        release << true
        holder.kill unless holder.join(5)
        holder.join
      end

      expect(TimekeepingOwnership.current.admission_fenced_at).to be_nil
    end
  end

  context "more tests 22" do
    # "After `fence_admission` returns, and before close_admission runs, a LocalOwner write, a BillingFence write and a Gateway write are each refused and commit nothing."
    it "after fence_admission returns a BillingFence write is refused with OwnershipMoving and commits no payment" do
      company = create(:company)
      client = create(:client, company:)
      invoice = create(:invoice, company:, client:, status: :sent)

      described_class.new.fence_admission

      expect(TimekeepingOwnership.current.handoff_step).to be_nil
      expect do
        Timekeeping::BillingFence.transaction do
          Payment.create!(invoice_id: invoice.id, transaction_date: Date.current, transaction_type: "cash", amount: 10,
                          note: "after fence")
        end
      end.to raise_error(Timekeeping::BillingFence::OwnershipMoving)
      expect(Payment.where(invoice_id: invoice.id).count).to eq(0)
    end
  end

  context "more tests 23" do
    # "`admit(generation:)` clears `admission_fenced_at`. The flip and abort already clear `handoff_step`."
    it "admit clears admission_fenced_at and billing writes are admitted again" do
      adapter = described_class.new
      adapter.fence_admission
      expect(TimekeepingOwnership.current.admission_fenced_at).not_to be_nil

      adapter.admit(generation: TimekeepingOwnership.current.generation)

      expect(TimekeepingOwnership.current.admission_fenced_at).to be_nil
      expect(Timekeeping::BillingFence.transaction { :billing_write_done }).to eq(:billing_write_done)
    end
  end

  context "more tests 24" do
    # A rollback runs admit on a monolith that was never fenced, so admit must be harmless there.
    it "admit on an unfenced row succeeds and changes no other ownership column" do
      before = TimekeepingOwnership.current.attributes

      expect { described_class.new.admit(generation: 1) }.not_to raise_error
      expect { described_class.new.admit(generation: 1) }.not_to raise_error

      expect(TimekeepingOwnership.current.attributes).to eq(before)
    end
  end

  context "more tests 25" do
    it "admit refuses a nil or non-positive generation and leaves the mark set" do
      adapter = described_class.new
      adapter.fence_admission

      [nil, 0, -1, "1"].each do |generation|
        expect { adapter.admit(generation:) }.to raise_error(ArgumentError)
      end

      expect(TimekeepingOwnership.current.admission_fenced_at).not_to be_nil
    end
  end

  context "more tests 26" do
    it "fence_admission raises RecordNotFound when the ownership row is missing and creates no row" do
      TimekeepingOwnership.delete_all

      expect { described_class.new.fence_admission }.to raise_error(ActiveRecord::RecordNotFound)
      expect(TimekeepingOwnership.count).to eq(0)
    end
  end

  context "more tests 27" do
    # "`admit` clears the mark, and `enforces_fence?` returns true."
    it "enforces_fence? is true and the adapter answers every admission method the capability gate checks" do
      adapter = described_class.new

      expect(adapter.enforces_fence?).to be(true)
      Timekeeping::Handoff::Capabilities::ADMISSION_METHODS.each do |method|
        expect(adapter).to respond_to(method)
      end
      expect(described_class::FENCE_LOCK_TIMEOUT).to eq(60.seconds)
    end
  end

  context "more tests 28", committed_data: true do
    # "In `Runner#close_admission`, clear `admission_fenced_at` in the same `update_all` that sets `handoff_step`."
    it "close_admission clears admission_fenced_at in the same update that sets handoff_step" do
      store = Object.new
      owners = TimekeepingHandoffFakes.owners(
        timekeeping: store, timekeeping_admission: TimekeepingHandoffFakes::RecordingAdmission.new,
        monolith_admission: described_class.new(lock_timeout: 0.3.seconds), monolith_store: store,
        settle: nil, relay: false
      )
      observer = TimekeepingHandoffHooks::Interrupt.new(at: :after_close_admission)
      ownership_updates = []
      record_update = lambda do |*, payload|
        sql = payload[:sql].to_s
        ownership_updates << sql if sql.start_with?("UPDATE") && sql.include?("timekeeping_ownership")
      end

      Dir.mktmpdir do |report_root|
        ActiveSupport::Notifications.subscribed(record_update, "sql.active_record") do
          expect do
            Timekeeping::Handoff::Runner.run(direction: :cutover, owners:, observer:, report_root:)
          end.to raise_error(TimekeepingHandoffHooks::Interrupted)
        end
      end

      closed = TimekeepingOwnership.current
      expect(closed.handoff_step).to eq("close_admission")
      expect(closed.admission_fenced_at).to be_nil
      step_updates = ownership_updates.select { |sql| sql.include?("handoff_step") }
      expect(step_updates).not_to be_empty
      expect(step_updates).to all(include("admission_fenced_at"))
    end
  end

  context "more tests 29" do
    # "After `fence_admission` returns, and before close_admission runs, a LocalOwner write, a BillingFence write and a Gateway write are each refused and commit nothing."
    # The user write and the NOWAIT reservation path both reach WriteSteps.admitted_generation, so this one
    # call covers the shared check; the refusal is answered as stale_generation, not ownership_moving.
    it "after fence_admission returns a LocalOwner create at the current generation is refused with stale_generation and writes nothing" do
      generation = prepare_local_ownership!.generation
      company = create(:company)
      user = timekeeping_member(company, "employee")
      project = create(:project, client: create(:client, company:))
      create_entry = lambda do |key|
        Timekeeping::LocalOwner.call(
          operation: :create, company_id: company.id, generation: generation.to_s,
          actor: Timekeeping::LocalOwner::Actor.user(user_id: user.id, role: "employee"),
          params: { "idempotency_key" => key,
                    "body" => { "project_id" => project.id, "work_date" => Date.current.iso8601, "duration" => 15.0,
                                "note" => "fenced", "source" => "manual", "source_metadata" => {} } }
        )
      end
      # The writer is admitted before the fence, so the refusal below comes from the fence alone.
      expect(create_entry.call("monolith-admission-before-fence").status).to eq(201)
      before = timekeeping_row_counts

      described_class.new(lock_timeout: 0.3.seconds).fence_admission

      ownership = TimekeepingOwnership.current
      expect(ownership.handoff_step).to be_nil
      expect(ownership.generation).to eq(generation)
      refused = create_entry.call("monolith-admission-after-fence")
      expect(refused.status).to eq(409)
      expect(refused.body.to_h.stringify_keys["reason"].to_s).to eq("stale_generation")
      expect(timekeeping_row_counts).to eq(before)
    end
  end

  context "more tests 30" do
    # "After `fence_admission` returns, and before close_admission runs, a LocalOwner write, a BillingFence write and a Gateway write are each refused and commit nothing."
    it "after fence_admission returns a Gateway create is refused with OwnershipMoving and commits no timesheet entry" do
      company = create(:company)
      admin = create(:user, current_workspace_id: company.id)
      create(:employment, company:, user: admin)
      admin.add_role :admin, company
      project = create(:project, billable: true, client: create(:client, company:))
      context = Timekeeping::WriteContext.new(company:, actor: admin, actor_kind: "user", request_id: "req-monolith-fence")
      attributes = { duration: 30, work_date: Date.current, note: "fenced", bill_status: "unbilled" }
      # The legacy gateway is admitted before the fence, so the refusal below comes from the fence alone.
      expect(Timekeeping::Gateway.new(context:).create(user: admin, project:, attributes:)).to be_persisted

      described_class.new(lock_timeout: 0.3.seconds).fence_admission

      expect(TimekeepingOwnership.current.handoff_step).to be_nil
      expect do
        expect { Timekeeping::Gateway.new(context:).create(user: admin, project:, attributes:) }
          .to raise_error(Timekeeping::Gateway::OwnershipMoving)
      end.not_to change(TimesheetEntry, :count)
    end
  end

  context "more tests 31", committed_data: true do
    it "fence_admission past the lock timeout raises, leaves no mark and restores lock_timeout" do
      admission = described_class.new(lock_timeout: 0.3.seconds)
      held = Queue.new
      release = Queue.new
      holder = committed_data_thread do
        TimekeepingOwnership.transaction do
          TimekeepingOwnership.lock("FOR SHARE").find(TimekeepingOwnership::SINGLETON_ID)
          held << true
          release.pop
        end
      end

      begin
        expect(held.pop(timeout: 5)).to be(true)
        default_timeout = ActiveRecord::Base.connection.select_value("SHOW lock_timeout")

        # "A holder kept past the lock timeout makes `fence_admission` raise and leaves no mark."
        expect { admission.fence_admission }.to raise_error(ActiveRecord::LockWaitTimeout)
        expect(ActiveRecord::Base.connection.select_value("SHOW lock_timeout")).to eq(default_timeout)
      ensure
        release << true
        holder.kill unless holder.join(5)
        holder.join
      end

      expect(TimekeepingOwnership.current.admission_fenced_at).to be_nil
      expect(TimekeepingOwnership.current.admission_closed?).to be(false)
    end
  end

  context "more tests 32" do
    it "fence_admission with the ownership row missing raises instead of reporting a fence" do
      TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).delete_all

      # A fence that changed no row must not return as if writes were stopped.
      expect { described_class.new(lock_timeout: 0.3.seconds).fence_admission }
        .to raise_error(ActiveRecord::RecordNotFound)
      expect(TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID)).not_to exist
    end
  end

  context "more tests 33", committed_data: true do
    it "a repeated fence stays fenced and billing stays refused until admit, which is harmless when repeated" do
      admission = described_class.new(lock_timeout: 0.3.seconds)

      admission.fence_admission
      admission.fence_admission
      expect(TimekeepingOwnership.current.admission_fenced_at).not_to be_nil

      # "After fence_admission returns, LocalOwner, BillingFence and Gateway writes are each refused until close_admission or admit"
      expect { Timekeeping::BillingFence.transaction { nil } }
        .to raise_error(Timekeeping::BillingFence::OwnershipMoving)

      before = TimekeepingOwnership.current
      admission.admit(generation: before.generation)
      admission.admit(generation: before.generation)

      after = TimekeepingOwnership.current
      expect(after.admission_fenced_at).to be_nil
      expect(after.slice(:generation, :handoff_step, :owner, :monolith_store))
        .to eq(before.slice(:generation, :handoff_step, :owner, :monolith_store))
      expect { Timekeeping::BillingFence.transaction { nil } }.not_to raise_error
    end
  end

  context "more tests 34" do
    it "admit with a nil generation is refused and leaves the fence in place" do
      TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).update_all(admission_fenced_at: Time.current)
      admission = described_class.new(lock_timeout: 0.3.seconds)

      expect { admission.admit(generation: nil) }.to raise_error(ArgumentError)
      expect { admission.admit(generation: 0) }.to raise_error(ArgumentError)
      expect(TimekeepingOwnership.current.admission_closed?).to be(true)
    end
  end

  context "more tests 35", committed_data: true do
    it "a billing write that starts while fence_admission waits is refused once the fence commits" do
      admission = described_class.new(lock_timeout: 5.seconds)
      holder_pids = Queue.new
      fence_pids = Queue.new
      held = Queue.new
      release = Queue.new
      holder = committed_data_thread(holder_pids) do
        TimekeepingOwnership.transaction do
          TimekeepingOwnership.lock("FOR SHARE").find(TimekeepingOwnership::SINGLETON_ID)
          held << true
          release.pop
        end
      end
      fence = nil
      late_writer = nil

      begin
        expect(held.pop(timeout: 5)).to be(true)
        holder_pid = holder_pids.pop
        fence = committed_data_thread(fence_pids) { admission.fence_admission }
        fence_pid = fence_pids.pop

        # "closing takes an exclusive lock on that row, so it waits for the transactions already admitted and none can commit after it"
        expect(blocked_by?(fence_pid, holder_pid, within: 3)).to be(true)

        late_writer = committed_data_thread do
          Timekeeping::BillingFence.transaction { :committed }
        rescue Timekeeping::BillingFence::OwnershipMoving
          :refused
        end
      ensure
        release << true
        [holder, fence, late_writer].compact.each { |thread| thread.kill unless thread.join(10) }
      end

      expect(fence.value).to be_nil
      expect(late_writer.value).to eq(:refused)
      expect(TimekeepingOwnership.current.admission_fenced_at).not_to be_nil
    end
  end

  context "close admission that does not complete", committed_data: true do
    # The real adapter, plus a step run right after its fence commits, so an
    # example can change the row between the fence and the runner's update.
    let(:after_fence_admission_class) do
      Class.new(SimpleDelegator) do
        def initialize(adapter, after_fence)
          super(adapter)
          @after_fence = after_fence
        end

        def fence_admission
          __getobj__.fence_admission
          @after_fence.call
          nil
        end
      end
    end

    def close_admission_owners(monolith_admission)
      store = Object.new
      {
        monolith: Timekeeping::Handoff::Owner.new(name: "monolith", store:, admission: monolith_admission,
                                                  settle: nil, drain: nil),
        timekeeping: Timekeeping::Handoff::Owner.new(name: "timekeeping", store:,
                                                     admission: TimekeepingHandoffFakes::RecordingAdmission.new,
                                                     settle: nil, drain: nil)
      }
    end

    it "keeps admission_fenced_at when the close_admission update matches no row" do
      step_set_elsewhere = lambda do
        TimekeepingOwnership.where(id: TimekeepingOwnership::SINGLETON_ID).update_all(handoff_step: "settle")
      end
      monolith_admission = after_fence_admission_class.new(described_class.new(lock_timeout: 0.3.seconds),
                                                           step_set_elsewhere)

      Dir.mktmpdir do |report_root|
        expect do
          Timekeeping::Handoff::Runner.run(direction: :cutover, owners: close_admission_owners(monolith_admission),
                                           report_root:, close_admission_lock_timeout: 0.3.seconds)
        end.to raise_error(Timekeeping::Handoff::Runner::Refused)
      end

      # "It fails closed, not open."
      ownership = TimekeepingOwnership.current
      expect(ownership.admission_fenced_at).not_to be_nil
      expect(ownership.handoff_step).to eq("settle")
      expect(ownership.generation).to eq(1)
    end

    it "keeps admission_fenced_at after a close_admission lock timeout until an abort run admits the monolith" do
      held = Queue.new
      release = Queue.new
      billing_write = nil
      # The holder starts only after the fence commits, so only the runner's own update waits on it.
      start_holder = lambda do
        billing_write = committed_data_thread do
          TimekeepingOwnership.transaction do
            TimekeepingOwnership.lock("FOR SHARE").find(TimekeepingOwnership::SINGLETON_ID)
            held << true
            release.pop
          end
        end
        raise "the FOR SHARE holder did not start" unless held.pop(timeout: 5)
      end
      monolith_admission = after_fence_admission_class.new(described_class.new(lock_timeout: 0.3.seconds), start_holder)
      owners = close_admission_owners(monolith_admission)

      Dir.mktmpdir do |report_root|
        begin
          expect do
            Timekeeping::Handoff::Runner.run(direction: :cutover, owners:, report_root:,
                                             close_admission_lock_timeout: 0.3.seconds)
          end.to raise_error(Timekeeping::Handoff::Runner::Refused)
        ensure
          release << true
          billing_write&.join(5) || billing_write&.kill&.join
        end

        # "if close_admission fails after the fence, the monolith stays closed until a later run succeeds or `admit` runs"
        timed_out = TimekeepingOwnership.current
        expect(timed_out.handoff_step).to be_nil
        expect(timed_out.admission_fenced_at).not_to be_nil
        expect(timed_out.admission_closed?).to be(true)

        Timekeeping::Handoff::Runner.run(direction: :cutover, abort: true, owners:, report_root:)
      end

      reopened = TimekeepingOwnership.current
      expect(reopened.admission_fenced_at).to be_nil
      expect(reopened.attributes.slice("generation", "handoff_step")).to eq("generation" => 1, "handoff_step" => nil)
    end
  end
end
