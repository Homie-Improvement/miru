RSpec.describe "Timekeeping queue ledger per-process path" do
  # "Under bin/parallel_test each process resolves its own ledger path, so one process's suite-start delete cannot remove another process's ledger file."
  it "the first parallel process and process 2 resolve different default ledger files" do
    first = TimekeepingQueueLedger.ledger_path({ "TEST_ENV_NUMBER" => "" })
    second = TimekeepingQueueLedger.ledger_path({ "TEST_ENV_NUMBER" => "2" })
    third = TimekeepingQueueLedger.ledger_path({ "TEST_ENV_NUMBER" => "3" })

    expect([first, second, third].uniq.size).to eq(3)
    expect(first).to eq(Rails.root.join("tmp/timekeeping-integration/queue_ledger.json").to_s)
    expect(second).to eq(Rails.root.join("tmp/timekeeping-integration/queue_ledger.2.json").to_s)
    expect(third).to eq(Rails.root.join("tmp/timekeeping-integration/queue_ledger.3.json").to_s)
  end
end
