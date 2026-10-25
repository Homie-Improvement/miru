# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "timekeeping:record_seed_disposition" do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @record_task_output = File.join(dir, "seed_disposition.yml")
      env_before = ENV.to_h.slice("MIRU_SEED_AS_OF", "OUTPUT")
      ENV["OUTPUT"] = @record_task_output
      ENV["MIRU_SEED_AS_OF"] = "2026-10-23"
      example.run
    ensure
      %w[MIRU_SEED_AS_OF OUTPUT].each { |key| ENV[key] = env_before[key] }
    end
  end

  before do
    Rake::Task["timekeeping:record_seed_disposition"].reenable
  end

  def invoke_record_task
    Rake::Task["timekeeping:record_seed_disposition"].invoke
  end

  it "refuses a database holding a user with no company, writing nothing and leaving the user unchanged" do
    user = create(:user, email: "dana@forkandleaf.example", current_workspace: nil, first_name: "Existing")
    Company.delete_all

    expect { invoke_record_task }
      .to raise_error(SystemExit).and output(/Refusing to load the seed over existing data/).to_stderr

    expect(File).not_to exist(@record_task_output)
    expect(user.reload.first_name).to eq("Existing")
  end

  it "refuses a database holding a company, leaving entry lock state unchanged" do
    company = create(:company)
    project = create(:project, client: create(:client, company:), billable: true)
    entry = create(:timesheet_entry, user: create(:user, current_workspace_id: company.id), project:, bill_status: "unbilled")
    entry.update_columns(locked: true)

    expect { invoke_record_task }.to raise_error(SystemExit).and output(/companies/).to_stderr

    expect(File).not_to exist(@record_task_output)
    expect(entry.reload.locked).to be(true)
  end

  it "aborts when MIRU_SEED_AS_OF is not set" do
    ENV.delete("MIRU_SEED_AS_OF")

    expect { invoke_record_task }.to raise_error(SystemExit).and output(/Set MIRU_SEED_AS_OF/).to_stderr
    expect(File).not_to exist(@record_task_output)
  end

  it "refuses to run in production" do
    allow(Rails.env).to receive(:production?).and_return(true)

    expect { invoke_record_task }.to raise_error(SystemExit).and output(/production/).to_stderr
    expect(File).not_to exist(@record_task_output)
  end
end
