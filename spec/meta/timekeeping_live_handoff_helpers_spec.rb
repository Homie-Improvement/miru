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

    it "lists the unsent positions of only the given company, in order" do
      live_handoff_connection.exec("INSERT INTO outbox_snapshots VALUES (0, 13, 1, NULL)")

      expect(described_class.queued_positions(live_handoff_connection, company_id: 1)).to eq([0, 2, 3])
      expect(described_class.queued_positions(live_handoff_connection, company_id: 2)).to eq([4])
    end
  end

  describe ".relay_batches" do
    # One outbox row as PostgreSQL returns it in text form: bigint, float,
    # boolean, date and timestamp columns as text, jsonb as its stored text.
    def live_handoff_stored_row(outbox_position:, metadata_text:)
      {
        "id" => "11", "project_id" => "3", "user_id" => "4", "agent_id" => nil, "work_date" => "2026-03-02",
        "duration" => "90.5", "note" => "Queued", "bill_status" => "unbilled", "review_status" => "pending",
        "locked" => "f", "source" => "manual", "source_metadata" => metadata_text, "external_run_id" => nil,
        "external_session_id" => nil, "proof_url" => nil, "proof_metadata" => "{}", "discarded_at" => nil,
        "created_at" => "2026-03-02 09:00:00.123456", "updated_at" => "2026-03-02 09:30:00.5",
        "company_id" => "1", "version" => "2", "generation" => "3", "outbox_position" => outbox_position.to_s
      }
    end

    # The same row as Timekeeping::RelayOutboxSource#relay_row offers it to the relay.
    def live_handoff_relay_row(outbox_position:, metadata:)
      {
        "generation" => 3, "outbox_position" => outbox_position,
        "entry" => {
          "id" => 11, "project_id" => 3, "user_id" => 4, "agent_id" => nil, "work_date" => Date.new(2026, 3, 2),
          "duration" => 90.5, "note" => "Queued", "bill_status" => "unbilled", "review_status" => "pending",
          "locked" => false, "source" => "manual", "source_metadata" => metadata, "external_run_id" => nil,
          "external_session_id" => nil, "proof_url" => nil, "proof_metadata" => {}, "discarded_at" => nil,
          "created_at" => "2026-03-02T09:00:00.123456Z", "updated_at" => "2026-03-02T09:30:00.500000Z",
          "company_id" => 1, "version" => 2
        }
      }
    end

    # Runs the real relay over the relay-shaped rows and records what it posts.
    def live_handoff_relay_posts(rows)
      posts = []
      source = Object.new
      source.define_singleton_method(:unsent_after) do |position, limit|
        rows.select { |row| row.fetch("outbox_position") > position }.first(limit)
      end
      source.define_singleton_method(:mark_sent) { |_positions| nil }
      endpoint = Object.new
      endpoint.define_singleton_method(:deliver) do |batch, idempotency_key:|
        posts << [TimekeepingRelay::BatchJson.generate(batch), idempotency_key]
        TimekeepingRelay::Response.new(status: 200, body: { "applied" => batch.fetch("snapshots").size, "ignored" => 0 })
      end
      TimekeepingRelay::Relay.new(source:, endpoint:).deliver(limit: described_class::RELAY_BATCH_SIZE)
      posts
    end

    it "rebuilds the body and Idempotency-Key the relay posts, keeping a fine decimal exact" do
      metadata_text = '{"rate": 0.1000000000000000055511151231257827}'
      stored = [live_handoff_stored_row(outbox_position: 7, metadata_text:),
                live_handoff_stored_row(outbox_position: 8, metadata_text:)]
      offered = [7, 8].map do |position|
        live_handoff_relay_row(outbox_position: position,
                               metadata: { "rate" => BigDecimal("0.1000000000000000055511151231257827") })
      end

      batches = described_class.relay_batches(stored)

      expect(batches.map { |batch| [batch.body, batch.idempotency_key] }).to eq(live_handoff_relay_posts(offered))
      expect(batches.first.body).to include('"created_at":"2026-03-02T09:00:00.123456Z"')
      expect(batches.first.body).to include('"rate":0.1000000000000000055511151231257827')
    end

    it "splits rows into batches of the relay's batch size" do
      stored = (1..(described_class::RELAY_BATCH_SIZE + 1)).map do |position|
        live_handoff_stored_row(outbox_position: position, metadata_text: "{}")
      end

      expect(described_class.relay_batches(stored).map { |batch| JSON.parse(batch.body).fetch("snapshots").size })
        .to eq([described_class::RELAY_BATCH_SIZE, 1])
    end
  end

  describe ".ownership_row_text" do
    it "reads the ownership table's row as row_to_json text past the query cache" do
      TimekeepingOwnership.ensure_initial!
      table = TimekeepingOwnership.table_name

      ActiveRecord::Base.cache do
        before = described_class.ownership_row_text
        expect(JSON.parse(before)).to include("id" => TimekeepingOwnership::SINGLETON_ID)
        ActiveRecord::Base.connection.raw_connection.exec(
          "UPDATE #{table} SET changed_by = 'live handoff helpers spec' WHERE id = #{TimekeepingOwnership::SINGLETON_ID}"
        )

        expect(JSON.parse(described_class.ownership_row_text)).to include("changed_by" => "live handoff helpers spec")
      end
    end
  end

  describe "entry snapshot receipt readers" do
    def live_handoff_receipt(key:, applied:, company_ids: [1, 2])
      EntrySnapshotReceipt.create!(actor: "timekeeping", company_ids:, key:, request_digest: "digest-#{key}",
                                   response_status: 200, response_body: { "applied" => applied, "ignored" => 0 },
                                   created_at: Time.current, expires_at: 1.day.from_now)
    end

    it "sums applied once for each receipt written after the baseline, whatever companies it covers" do
      live_handoff_receipt(key: "before", applied: 5)
      baseline = described_class.snapshot_receipt_baseline
      first = live_handoff_receipt(key: "first", applied: 3)
      second = live_handoff_receipt(key: "second", applied: 2, company_ids: [1])

      expect(described_class.snapshot_receipts_after(baseline))
        .to eq([described_class::SnapshotReceipt.new(id: first.id, key: "first", applied: 3),
                described_class::SnapshotReceipt.new(id: second.id, key: "second", applied: 2)])
      expect(described_class.applied_after(baseline)).to eq(5)
    end

    # The runtime writes receipts through its own connections, which do not
    # clear this process's query cache; a raw insert does the same here.
    it "reads the baseline and the receipts past the query cache" do
      ActiveRecord::Base.cache do
        baseline = described_class.snapshot_receipt_baseline
        expect(described_class.snapshot_receipts_after(baseline)).to eq([])
        ActiveRecord::Base.connection.raw_connection.exec(<<~SQL)
          INSERT INTO entry_snapshot_receipts (actor, company_ids, key, request_digest, response_status, response_body,
                                               created_at, expires_at)
          VALUES ('timekeeping', '{1}', 'raw', 'digest-raw', 200, '{"applied": 4, "ignored": 0}', now(),
                  now() + interval '1 day')
        SQL

        expect(described_class.snapshot_receipt_baseline).to be > baseline
        expect(described_class.applied_after(baseline)).to eq(4)
      end
    end
  end

  describe ".tenant_digest" do
    it "passes the Timekeeping database URL, not the runtime's HTTP address" do
      allow(TenantStateDigest).to receive(:take).and_return(:digest)
      env = { TimekeepingDatabaseReset::DATABASE_URL_KEY => "postgres://db/timekeeping_test" }

      expect(described_class.tenant_digest(company_id: 4, env:)).to eq(:digest)
      expect(TenantStateDigest).to have_received(:take).with(company_id: 4, timekeeping_url: "postgres://db/timekeeping_test")
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
