require "rails_helper"
require "json"
require "open3"

RSpec.describe "app/javascript/src/apis/idempotencyKey.ts keyForSend" do
  # "The web and mobile clients send one Idempotency-Key per user action, reused on retry, so a retried write replays the stored answer instead of using the per-request fallback key."
  it "reuses a form's held Idempotency-Key for an unchanged resubmit and makes a new one for a changed body or a new action" do
    module_url = "file://#{Rails.root.join("app/javascript/src/apis/idempotencyKey.ts")}"
    script = <<~JS
      const { keyForSend } = await import(#{module_url.to_json});
      let counter = 0;
      const newKey = () => `key-${++counter}`;
      const body = { project_id: 11, timesheet_entry: { duration: 30, note: "same" } };
      const first = keyForSend(null, body, newKey);
      const resubmit = keyForSend(first, { project_id: 11, timesheet_entry: { duration: 30, note: "same" } }, newKey);
      const edited = keyForSend(first, { project_id: 11, timesheet_entry: { duration: 45, note: "same" } }, newKey);
      const otherForm = keyForSend(null, body, newKey);
      console.log(JSON.stringify({ first: first.key, resubmit: resubmit.key, edited: edited.key, otherForm: otherForm.key }));
    JS
    stdout, stderr, status = Open3.capture3("node", "--experimental-strip-types", "--input-type=module", "-e", script)

    expect(status).to be_success, stderr
    keys = JSON.parse(stdout.lines.last)
    expect(keys["first"]).to eq("key-1")
    expect(keys["resubmit"]).to eq(keys["first"])
    expect(keys["edited"]).not_to eq(keys["first"])
    expect(keys["otherForm"]).not_to eq(keys["first"])
    expect(keys["otherForm"]).not_to eq(keys["edited"])
  end
end

require "rails_helper"
require "json"
require "open3"

RSpec.describe "app/javascript/src/apis/idempotencyKey.ts afterAnswer" do
  # "The web and mobile clients send one Idempotency-Key per user action, reused on retry, so a retried write replays the stored answer instead of using the per-request fallback key."
  it "keeps the held Idempotency-Key after a failed answer and drops it after a successful one" do
    module_url = "file://#{Rails.root.join("app/javascript/src/apis/idempotencyKey.ts")}"
    script = <<~JS
      const { keyForSend, afterAnswer } = await import(#{module_url.to_json});
      let counter = 0;
      const newKey = () => `key-${++counter}`;
      const body = { project_id: 11, timesheet_entry: { duration: 0, note: "" } };
      const held = keyForSend(null, body, newKey);
      const afterFailure = afterAnswer(held, false);
      const retry = keyForSend(afterFailure, body, newKey);
      const afterSuccess = afterAnswer(retry, true);
      const nextAction = keyForSend(afterSuccess, body, newKey);
      console.log(JSON.stringify({ held: held.key, afterFailure, retry: retry.key, afterSuccess, nextAction: nextAction.key }));
    JS
    stdout, stderr, status = Open3.capture3("node", "--experimental-strip-types", "--input-type=module", "-e", script)

    expect(status).to be_success, stderr
    result = JSON.parse(stdout.lines.last)
    expect(result["afterFailure"]).to include("key" => result["held"])
    expect(result["retry"]).to eq(result["held"])
    expect(result["afterSuccess"]).to be_nil
    expect(result["nextAction"]).not_to eq(result["held"])
  end
end

require "rails_helper"
require "json"
require "open3"

RSpec.describe "app/javascript/src/apis/idempotencyKey.ts isEntryGatewayWrite" do
  # "The web and mobile clients send one Idempotency-Key per user action, reused on retry, so a retried write replays the stored answer instead of using the per-request fallback key."
  it "treats only state-changing timesheet entry and bulk action requests as entry gateway writes" do
    module_url = "file://#{Rails.root.join("app/javascript/src/apis/idempotencyKey.ts")}"
    cases = [
      ["post", "/timesheet_entry", true],
      ["post", "/timesheet_entry?user_id=5", true],
      ["put", "/timesheet_entry/42", true],
      ["delete", "/timesheet_entry/42", true],
      ["delete", "/timesheet_entry/bulk_action/", true],
      ["patch", "/timesheet_entry/bulk_action/", true],
      ["get", "/timesheet_entry", false],
      ["get", "/timesheet_entry/42", false],
      ["post", "/timeoff_entries?user_id=5", false],
      ["put", "/timeoff_entries/3", false]
    ]
    script = <<~JS
      const { isEntryGatewayWrite } = await import(#{module_url.to_json});
      const cases = #{cases.to_json};
      console.log(JSON.stringify(cases.map(([method, url]) => isEntryGatewayWrite(method, url))));
    JS
    stdout, stderr, status = Open3.capture3("node", "--experimental-strip-types", "--input-type=module", "-e", script)

    expect(status).to be_success, stderr
    expect(JSON.parse(stdout.lines.last)).to eq(cases.map(&:last))
  end
end
