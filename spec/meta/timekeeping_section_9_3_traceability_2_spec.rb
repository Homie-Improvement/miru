# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimekeepingSection93Traceability do
  context "more tests 2" do
    # "Raise ArgumentError on a duplicate Case or when the 9.3 heading or table is missing, so a collapsed or misplaced parse fails instead of shrinking silently."
    it "rows raises on a row whose escaped pipe splits it into five cells instead of dropping it" do
      control = <<~MARKDOWN
        ### 9.3 Failure cases

        | Case | State that survives | How it is detected and repaired | Proving test |
        |---|---|---|---|
        | Relay down | Outbox rows stay unsent | Relay resumes | Integration: stop the relay |
        | Two invoices prepare one entry at once | One reservation | Serialize | Concurrency: two prepares |
        | Stale generation | No change | 409 | Contract: old generation |
      MARKDOWN
      broken = control.sub("| Relay down | Outbox rows stay unsent |", "| Relay down | Outbox \\| rows stay unsent |")

      expect(described_class.rows(control).keys).to eq(["Relay down", "Two invoices prepare one entry at once"])
      expect { described_class.rows(broken) }.to raise_error(ArgumentError)
    end
  end

  context "more tests 3" do
    # "Raise ArgumentError on a duplicate Case or when the 9.3 heading or table is missing, so a collapsed or misplaced parse fails instead of shrinking silently."
    it "rows raises when the 9.3 heading appears twice or has no table under it" do
      table = <<~MARKDOWN
        ### 9.3 Failure cases

        | Case | State that survives | How it is detected and repaired | Proving test |
        |---|---|---|---|
        | Relay down | Outbox rows stay unsent | Relay resumes | Integration: stop the relay |
      MARKDOWN
      copied_section = "#{table}\nSome prose.\n\n#{table.sub('Relay down', 'Relay gone')}"
      heading_without_table = <<~MARKDOWN
        ### 9.3 Failure cases

        The table moved to an appendix.

        | Case | State that survives | How it is detected and repaired | Proving test |
        |---|---|---|---|
        | Relay down | Outbox rows stay unsent | Relay resumes | Integration: stop the relay |
      MARKDOWN

      expect { described_class.rows(copied_section) }.to raise_error(ArgumentError)
      expect { described_class.rows(heading_without_table) }.to raise_error(ArgumentError)
    end
  end

  context "more tests 4" do
    # "Count the two kinds separately, not as a total of 15, so a Contract row parsed as Integration still fails."
    it "rows classifies only by the Proving test cell so a Contract row mentioning Integration elsewhere is left out" do
      markdown = <<~MARKDOWN
        ### 9.3 Failure cases

        | Case | State that survives | How it is detected and repaired | Proving test |
        |---|---|---|---|
        | Integration: looks like a marker | Integration: survives | Integration: repaired | Contract: really a contract row |
        | Relay down | Outbox rows stay unsent | Relay resumes | Integration: stop the relay |
        | Two invoices prepare one entry at once | One reservation | Serialize | Concurrency: two prepares, Integration: no |
      MARKDOWN

      rows = described_class.rows(markdown)

      expect(rows.keys).to eq(["Relay down", "Two invoices prepare one entry at once"])
      expect(rows.fetch("Two invoices prepare one entry at once").kind).to eq(:concurrency)
      expect(rows.fetch("Relay down").kind).to eq(:integration)
    end
  end

  context "more tests 5" do
    # "`missing` matches each example name to the longest Case text it starts with, so a short Case such as \"Relay down\" is never covered by an example for a longer Case that begins with it."
    it "missing credits only the longest Case a name starts with and reports the rest in table order" do
      markdown = <<~MARKDOWN
        ### 9.3 Failure cases

        | Case | State that survives | How it is detected and repaired | Proving test |
        |---|---|---|---|
        | Relay down extra | Something | Repaired | Integration: longer case |
        | Draft discarded | Released | Discard | Integration: discard |
        | Relay down | Outbox rows stay unsent | Relay resumes | Integration: stop the relay |
        | Two invoices prepare one entry at once | One reservation | Serialize | Concurrency: two prepares |
      MARKDOWN
      rows = described_class.rows(markdown)

      missing = described_class.missing(rows, ["Relay down extra case", "Relay down extra again", "Two invoices prepare one entry at once: one wins"])

      expect(missing).to eq(["Draft discarded", "Relay down"])
      expect(missing).to be_frozen
    end
  end

  context "more tests 6" do
    # "Return a frozen Hash of Case text to a `Row` value, `Data.define(:case_text, :survives, :proving_test, :kind)`, with kind `:integration` or `:concurrency`."
    it "rows result does not change when the markdown string is mutated afterwards" do
      markdown = +<<~MARKDOWN
        ### 9.3 Failure cases

        | Case | State that survives | How it is detected and repaired | Proving test |
        |---|---|---|---|
        | Relay down | Outbox rows stay unsent | Relay resumes | Integration: stop the relay |
      MARKDOWN

      rows = described_class.rows(markdown)
      markdown.replace("")
      row = rows.fetch("Relay down")

      expect(rows).to be_frozen
      expect([row.case_text, row.survives, row.proving_test, row.kind])
        .to eq(["Relay down", "Outbox rows stay unsent", "Integration: stop the relay", :integration])
      expect([row.case_text, row.survives, row.proving_test]).to all(be_frozen)
      expect { row.case_text << " changed" }.to raise_error(FrozenError)
    end
  end
end
