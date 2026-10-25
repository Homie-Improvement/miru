# frozen_string_literal: true

# How a replayed invoice save ends when prepare answers 200 with a terminal
# state (docs/architecture/timekeeping-soa.md section 9.2 step 3 and its
# section 9.3 row). Needs a reconciler let responding to
# call(remote_state:, intent_state:).
RSpec.shared_examples "timekeeping prepare reconciliation" do
  let(:table) { TimekeepingContract.load(:reservations).fetch("save_reconciliation") }

  it "returns the existing success, changing nothing, for a committed operation whose intent is committed" do
    expect(reconciler.call(remote_state: "committed", intent_state: "committed"))
      .to eq("outcome" => "existing_success", "retryable" => false, "changed" => false)
  end

  it "fails the save, changing nothing, for an aborted operation whose intent is failed" do
    expect(reconciler.call(remote_state: "aborted", intent_state: "failed"))
      .to eq("outcome" => "save_failed", "retryable" => false, "changed" => false)
  end

  it "gives a retryable reconciliation error, changing nothing, for a committed operation whose intent is still pending" do
    expect(reconciler.call(remote_state: "committed", intent_state: "pending"))
      .to eq("outcome" => "reconciliation_error", "retryable" => true, "changed" => false)
  end

  it "gives the retryable reconciliation error for every other pair" do
    listed = [["committed", "committed"], ["aborted", "failed"]]
    pairs = table.fetch("remote_states").product(table.fetch("intent_states")) - listed

    pairs.each do |remote_state, intent_state|
      expect([remote_state, intent_state, reconciler.call(remote_state:, intent_state:)])
        .to eq([remote_state, intent_state, { "outcome" => "reconciliation_error", "retryable" => true, "changed" => false }])
    end
  end
end
