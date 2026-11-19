# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe Timekeeping::Handoff::Drain do
  context "with an unsent snapshot the monolith refuses" do
    # "It answers `drained`, which is true only when no outbox_snapshots row with position at or below P has `sent_at` NULL."
    it "answers true for a through between a sent and an unsent position" do
      insert_outbox_rows(
        outbox_row(outbox_position: 10, id: 910, sent_at: Time.utc(2026, 3, 3, 9, 0, 0)),
        outbox_row(outbox_position: 20, id: 920)
      )
      # The monolith refuses every batch, so the relay run cannot send the row at 20.
      WebMock.stub_request(:post, "http://snapshots.test/internal/v1/timekeeping/entry-snapshots")
        .to_return(status: 503, body: "")

      drained = with_timekeeping_env(
        Timekeeping::Environment::MONOLITH_SNAPSHOT_URL => "http://snapshots.test",
        Timekeeping::Environment::SERVICE_TOKEN => "drain-spec-service-token"
      ) do
        described_class.call(through: 19)
      end

      expect(drained).to be(true)
      expect(OutboxSnapshot.where(outbox_position: 20).pick(:sent_at)).to be_nil
    end
  end

  context "once another connection releases the relay lock" do
    # The request spec owns what a held lock does to the drain answer. This
    # example observes the held-lock false answer only so that the true answer
    # after release shows a change.
    it "answers true after the relay lock is released when every row at or below through is sent" do
      insert_outbox_rows(outbox_row(outbox_position: 1, id: 811), outbox_row(outbox_position: 2, id: 812))
      OutboxSnapshot.update_all(sent_at: Time.current)
      WebMock.stub_request(:post, "http://drain-spec.test/internal/v1/timekeeping/entry-snapshots")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: "{}")

      other_connection = PG.connect(Timekeeping::Environment.database_url)
      with_timekeeping_env(
        Timekeeping::Environment::MONOLITH_SNAPSHOT_URL => "http://drain-spec.test",
        Timekeeping::Environment::SERVICE_TOKEN => "drain-spec-service-token"
      ) do
        begin
          other_connection.exec_params("SELECT pg_advisory_lock($1)", [RelayJob::RELAY_LOCK_KEY])

          expect(described_class.call(through: 2)).to be(false)
        ensure
          other_connection.close
        end

        # "It answers `drained`, which is true only when no outbox_snapshots row with
        # position at or below P has `sent_at` NULL."
        expect(described_class.call(through: 2)).to be(true)
      end
    end
  end

  context "when the relay leaves or sends rows at the drain position" do
    def with_drain_snapshot_endpoint(&)
      with_timekeeping_env(
        Timekeeping::Environment::MONOLITH_SNAPSHOT_URL => "http://drain-held.test",
        Timekeeping::Environment::SERVICE_TOKEN => "drain-spec-service-token", &
      )
    end

    let(:drain_snapshot_url) { "http://drain-held.test/internal/v1/timekeeping/entry-snapshots" }

    # The relay never offers rows of the held generation, yet they are unsent,
    # so drain stays false until admit releases them.
    it "answers false while an unsent row of the held generation sits at or below through" do
      Timekeeping::Admission.hold_generation!(5)
      position = insert_outbox_rows(outbox_row(id: 932, generation: 5)).first
      # The relay sends nothing here; a delivery answer is stubbed so a relay
      # that wrongly offered the held row would mark it sent.
      WebMock.stub_request(:post, drain_snapshot_url)
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("applied" => 1, "ignored" => 0))

      drained = with_drain_snapshot_endpoint { described_class.call(through: position) }

      expect(drained).to be(false)
      expect(OutboxSnapshot.where(outbox_position: position).pick(:sent_at)).to be_nil
    end

    it "answers for a through above the bigint range without a database error" do
      position = insert_outbox_rows(outbox_row(id: 933)).first
      WebMock.stub_request(:post, drain_snapshot_url).to_return(status: 503, body: "")

      unsent_answer = with_drain_snapshot_endpoint { described_class.call(through: 2**64) }
      OutboxSnapshot.where(outbox_position: position).update_all(sent_at: Time.current)
      sent_answer = with_drain_snapshot_endpoint { described_class.call(through: 2**64) }

      expect([unsent_answer, sent_answer]).to eq([false, true])
    end
  end
end
