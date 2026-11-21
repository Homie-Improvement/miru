# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe TimekeepingLiveHandoff do
  let(:failures) { [] }

  def live_handoff_response(code)
    instance_double(Net::HTTPResponse, code:)
  end

  def live_handoff_drain_double(drained_on_attempt:)
    attempts = 0
    drain = instance_double(Timekeeping::Handoff::RelayDrain)
    allow(drain).to receive(:drain!)
    allow(drain).to receive(:drained?) do
      attempts += 1
      attempts == drained_on_attempt
    end
    drain
  end

  describe ".catch_up!" do
    it "stops after the fixed number of attempts, naming the unsent positions, and never sleeps" do
      drain = live_handoff_drain_double(drained_on_attempt: nil)
      read_through = []
      unsent_positions = lambda { |through:|
        read_through << through
        [41, 42]
      }
      allow(described_class).to receive(:sleep)

      expect { described_class.catch_up!(drain:, through: 42, unsent_positions:, attempts: 3) }
        .to raise_error(described_class::CatchUpIncomplete,
                        "outbox positions [41, 42] at or below 42 were still unsent after 3 drain attempts; " \
                        "the runtime's relay worker may have held the relay lock")

      expect(drain).to have_received(:drain!).with(through: 42).exactly(3).times
      expect(drain).to have_received(:drained?).with(through: 42).exactly(3).times
      expect(read_through).to eq([42, 42, 42])
      expect(described_class).not_to have_received(:sleep)
    end

    it "returns as soon as drained? answers true" do
      drain = live_handoff_drain_double(drained_on_attempt: 2)

      expect(described_class.catch_up!(drain:, through: 7, unsent_positions: ->(through:) { [through] },
                                       attempts: 3)).to be_nil

      expect(drain).to have_received(:drain!).twice
      expect(drain).to have_received(:drained?).twice
    end

    # Timekeeping's drain answers false while the runtime's relay worker holds
    # the relay lock, even once that worker has sent every row.
    it "returns once no position at or below through is unsent, though drained? never answers true" do
      drain = live_handoff_drain_double(drained_on_attempt: nil)
      answers = [[6, 7], []]

      expect(described_class.catch_up!(drain:, through: 7, unsent_positions: ->(through:) { answers.shift },
                                       attempts: 3)).to be_nil

      expect(drain).to have_received(:drain!).twice
      expect(drain).to have_received(:drained?).twice
    end
  end

  describe ".resume_relay" do
    it "deletes the pause file and raises when the resume request answers 500" do
      Dir.mktmpdir do |directory|
        pause_file = Pathname(directory).join("relay_paused.test")
        FileUtils.touch(pause_file)

        expect { described_class.resume_relay(post: ->(_route) { live_handoff_response("500") }, pause_file:) }
          .to raise_error(described_class::HookRefused, "POST /internal/v1/test-hooks/relay/resume answered 500, expected 204")
        expect(pause_file).not_to exist
      end
    end

    it "posts the resume route and deletes the pause file when the request answers 204" do
      Dir.mktmpdir do |directory|
        pause_file = Pathname(directory).join("relay_paused.test")
        FileUtils.touch(pause_file)
        routes = []

        described_class.resume_relay(post: ->(route) { live_handoff_response("204").tap { routes << route } }, pause_file:)

        expect(routes).to eq(["/internal/v1/test-hooks/relay/resume"])
        expect(pause_file).not_to exist
      end
    end
  end

  describe ".pause_relay" do
    it "raises when the pause request does not answer 204" do
      expect { described_class.pause_relay(post: ->(_route) { live_handoff_response("404") }) }
        .to raise_error(described_class::HookRefused, "POST /internal/v1/test-hooks/relay/pause answered 404, expected 204")
    end
  end

  describe ".require_legacy_owner!" do
    it "accepts the legacy ownership columns and refuses the timekeeping ones" do
      legacy = { owner: "monolith", monolith_store: "legacy", legacy_retired_at: nil }

      expect(described_class.require_legacy_owner!(legacy)).to be_nil
      expect { described_class.require_legacy_owner!(legacy.merge(owner: "timekeeping")) }
        .to raise_error(described_class::NotLegacy, /starts from the legacy owner state/)
    end
  end

  describe ".run_session" do
    let(:live_handoff_env_key) { "TIMEKEEPING_LIVE_HANDOFF_HELPERS_SPEC" }

    def live_handoff_session(resume:, rebuild:, roots:, &body)
      described_class.run_session(
        failures:,
        within_env: ->(&block) { with_timekeeping_env(live_handoff_env_key => "inside", &block) },
        resume:, rebuild:,
        remove_report_roots: -> { roots.each { |root| FileUtils.rm_rf(root) } },
        &body
      )
    end

    it "runs every later teardown step when the resume request raises, and raises one error naming it" do
      Dir.mktmpdir do |directory|
        pause_file = Pathname(directory).join("relay_paused.test")
        root = Pathname(Dir.mktmpdir("live-handoff-helpers-spec"))
        env_seen_by_rebuild = []
        resume = lambda {
          described_class.resume_relay(post: ->(_route) { raise Errno::ECONNREFUSED }, pause_file:)
        }
        rebuild = -> { env_seen_by_rebuild << ENV.fetch(live_handoff_env_key, nil) }

        expect do
          live_handoff_session(resume:, rebuild:, roots: [root]) { FileUtils.touch(pause_file) }
        end.to raise_error(described_class::TeardownFailed, /\Ateardown failed: resume_relay: Errno::ECONNREFUSED/)

        expect(pause_file).not_to exist
        expect(ENV.fetch(live_handoff_env_key, nil)).to be_nil
        expect(env_seen_by_rebuild).to eq(["inside", nil])
        expect(root).not_to exist
        expect(failures).to contain_exactly(a_string_starting_with("resume_relay: Errno::ECONNREFUSED"))
      ensure
        FileUtils.rm_rf(root) if root
      end
    end

    it "keeps the body's exception when the rebuild also raises, and records the rebuild failure for the group check" do
      body_failure = Class.new(StandardError)
      rebuilds = 0
      rebuild = lambda {
        rebuilds += 1
        raise ArgumentError, "integrations not rebuilt" if rebuilds == 2
      }

      expect do
        live_handoff_session(resume: -> { }, rebuild:, roots: []) { raise body_failure, "invoice save answered 422" }
      end.to raise_error(body_failure, "invoice save answered 422")

      expect(failures).to eq(["rebuild_integrations: ArgumentError: integrations not rebuilt"])
      expect { described_class.assert_clean_teardowns!([{ full_description: "AC5 example", described_class::TEARDOWN_FAILURES_KEY => failures }]) }
        .to raise_error(described_class::TeardownFailed, /AC5 example: rebuild_integrations: ArgumentError: integrations not rebuilt/)
    end

    it "returns the body's result and records nothing when every step succeeds" do
      expect(live_handoff_session(resume: -> { }, rebuild: -> { }, roots: []) { :done }).to eq(:done)
      expect(failures).to be_empty
    end
  end

  describe ".assert_clean_teardowns!" do
    it "passes when no example recorded a failure" do
      expect(described_class.assert_clean_teardowns!([{ full_description: "clean" }, { described_class::TEARDOWN_FAILURES_KEY => [] }]))
        .to be_nil
    end
  end

  describe "Timekeeping database readers" do
    let(:live_handoff_connection) { ActiveRecord::Base.connection.raw_connection }

    # Temporary tables with only the columns the readers use, on this
    # session's connection, so no Timekeeping database is needed.
    around do |example|
      live_handoff_connection.exec(<<~SQL)
        CREATE TEMP TABLE outbox_snapshots (outbox_position bigint, id bigint, company_id bigint, sent_at timestamp);
        CREATE TEMP TABLE idempotency_receipts (company_id bigint);
        CREATE TEMP TABLE service_idempotency_receipts (company_id bigint);
      SQL
      example.run
    ensure
      live_handoff_connection.exec(
        "DROP TABLE IF EXISTS pg_temp.outbox_snapshots, pg_temp.idempotency_receipts, pg_temp.service_idempotency_receipts"
      )
    end

    before do
      live_handoff_connection.exec(<<~SQL)
        INSERT INTO outbox_snapshots VALUES (1, 10, 1, now()), (2, 11, 1, NULL), (3, 12, 1, NULL), (4, 20, 2, NULL);
        INSERT INTO idempotency_receipts VALUES (1), (1), (2);
        INSERT INTO service_idempotency_receipts VALUES (1), (2), (2);
      SQL
    end

    it "counts unsent outbox snapshots of only the given company, and of one entry" do
      expect(described_class.queued_count(live_handoff_connection, company_id: 1)).to eq(2)
      expect(described_class.queued_count(live_handoff_connection, company_id: 1, entry_id: 11)).to eq(1)
      expect(described_class.queued_count(live_handoff_connection, company_id: 1, entry_id: 10)).to eq(0)
      expect(described_class.queued_count(live_handoff_connection, company_id: 2)).to eq(1)
    end

    it "counts user and service receipts of only the given company" do
      expect(described_class.receipt_count(live_handoff_connection, company_id: 1)).to eq(3)
      expect(described_class.receipt_count(live_handoff_connection, company_id: 2)).to eq(3)
      expect(described_class.receipt_count(live_handoff_connection, company_id: 3)).to eq(0)
    end

    it "lists unsent positions at or below through in order" do
      expect(described_class.unsent_outbox_positions(live_handoff_connection, through: 3)).to eq([2, 3])
    end
  end

  describe ".money" do
    it "answers FinancialSnapshot.take and sees a change written past the query cache" do
      invoice = create(:invoice, amount: 100)
      company_id = invoice.company_id

      ActiveRecord::Base.cache do
        expect(described_class.money(company_id:)).to eq(Timekeeping::FinancialSnapshot.take(company_id:))
        ActiveRecord::Base.connection.raw_connection.exec_params("UPDATE invoices SET amount = 250 WHERE id = $1",
                                                                 [invoice.id])

        expect(described_class.money(company_id:).fetch(:values).fetch([:invoice, invoice.id, :amount])).to eq(250)
      end
    end
  end
end
