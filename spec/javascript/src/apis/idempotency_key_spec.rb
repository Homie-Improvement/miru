require "rails_helper"
require "open3"
require "json"

RSpec.describe "app/javascript/src/apis/idempotencyKey.ts" do
  it "an entry write whose answer was lost keeps its key for the unchanged retry, and a write that succeeded gives the next identical submit a new key" do
    module_url = "file://#{Rails.root.join("app/javascript/src/apis/idempotencyKey.ts")}"
    script = <<~JS
      import { keyForSend, afterAnswer } from #{module_url.to_json};
      let issued = 0;
      const newKey = () => `generated-key-${++issued}`;
      const body = { project_id: 7, timesheet_entry: { work_date: "2025-01-06", duration: 60, note: "Same" } };

      const firstSend = keyForSend(null, body, newKey);
      const afterLostAnswer = afterAnswer(firstSend, false);
      const retrySend = keyForSend(afterLostAnswer, body, newKey);
      const afterSuccess = afterAnswer(retrySend, true);
      const nextActionSend = keyForSend(afterSuccess, body, newKey);

      console.log(JSON.stringify({
        first: firstSend.key,
        retry: retrySend.key,
        afterSuccess,
        nextAction: nextActionSend.key
      }));
    JS

    stdout, stderr, status = Open3.capture3(
      "node", "--experimental-strip-types", "--no-warnings", "--input-type=module", "-e", script
    )
    expect(status).to be_success, stderr

    keys = JSON.parse(stdout.lines.last)
    # "The web and mobile clients send one Idempotency-Key per user action, reused on retry, so a retried write replays the stored answer instead of using the per-request fallback key."
    expect(keys["retry"]).to eq(keys["first"])
    # A key kept after a 2xx answer would make a deliberate second identical entry replay the first and never be written.
    expect(keys["afterSuccess"]).to be_nil
    expect(keys["nextAction"]).not_to eq(keys["first"])
  end
end
