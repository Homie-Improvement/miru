# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimekeepingSection93Traceability do
  let(:real_document) { Rails.root.join("docs/architecture/timekeeping-soa.md").read }

  describe ".rows" do
    # "Count the two kinds separately, not as a total of 15, so a Contract row parsed as Integration still fails."
    it "rows on the real document finds exactly 14 integration rows and 1 concurrency row" do
      rows = described_class.rows(real_document)

      expect(rows).to be_frozen
      expect(rows.values.count { |row| row.kind == :integration }).to eq(14)
      expect(rows.values.count { |row| row.kind == :concurrency }).to eq(1)
      expect(rows.select { |_, row| row.kind == :concurrency }.keys).to eq(["Two invoices prepare one entry at once"])
      expect(rows.keys).to include("Prepare answer lost (timeout or 5xx)")
    end

    # "Raise ArgumentError on a duplicate Case or when the 9.3 heading or table is missing, so a collapsed or misplaced parse fails instead of shrinking silently."
    it "rows raises on a duplicate Case, a missing 9.3 heading and a heading with no table" do
      header = "| Case | State that survives | How it is detected and repaired | Proving test |\n|---|---|---|---|\n"
      duplicate = "### 9.3 Failure cases\n\n#{header}" \
                  "| Same case | s1 | d1 | Integration: one |\n| Same case | s2 | d2 | Integration: two |\n"
      no_heading = "### 9.2 Other\n\n#{header}| Some case | s | d | Integration: x |\n"
      no_table = "### 9.3 Failure cases\n\nOnly prose here.\n"

      expect { described_class.rows(duplicate) }.to raise_error(ArgumentError, /Same case/)
      expect { described_class.rows(no_heading) }.to raise_error(ArgumentError, /9\.3/)
      expect { described_class.rows(no_table) }.to raise_error(ArgumentError, /table/)
    end

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

    # "Read only that table and stop at the first non-table line, so another table with a Proving test column elsewhere in the document is never counted."
    it "rows keeps raw Case text, leaves out Contract rows and never reads a second table" do
      header = "| Case | State that survives | How it is detected and repaired | Proving test |\n|---|---|---|---|\n"
      markdown = +"### 9.3 Failure cases\n\n#{header}"
      markdown << "| Prepare answer lost (timeout or 5xx) | intent `failed` | abort | Integration: drop the answer |\n"
      markdown << "| Refused: `on_another_invoice` | Integration: not here | d | Contract: 409 |\n"
      markdown << "| Two invoices prepare one entry at once | one | lock | Concurrency: parallel |\n"
      markdown << "| Prepare refused: `provisional_elsewhere` (retry) | none | retry | Integration: refuse |\n"
      markdown << "\nA paragraph ends the table.\n\n#{header}| Elsewhere case | s | d | Integration: other |\n"

      rows = described_class.rows(markdown)

      expect(rows.keys).to eq(["Prepare answer lost (timeout or 5xx)", "Two invoices prepare one entry at once",
                               "Prepare refused: `provisional_elsewhere` (retry)"])
      expect(rows.fetch("Prepare refused: `provisional_elsewhere` (retry)").case_text)
        .to eq("Prepare refused: `provisional_elsewhere` (retry)")
      row = rows.fetch("Prepare answer lost (timeout or 5xx)")
      expect(row.kind).to eq(:integration)
      expect(row.survives).to eq("intent `failed`")
      expect(row.proving_test).to eq("Integration: drop the answer")
      expect([row, row.case_text, row.survives, row.proving_test]).to all(be_frozen)
    end

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

    it "rows raises naming the Case when a Proving test prefix is mistyped instead of dropping the row" do
      control = <<~MARKDOWN
        ### 9.3 Failure cases

        | Case | State that survives | How it is detected and repaired | Proving test |
        |---|---|---|---|
        | Relay down | Outbox rows stay unsent | Relay resumes | Integration: stop the relay |
        | Draft discarded | Released | Discard | Integration: discard |
        | Stale generation | No change | 409 | Contract: old generation |
      MARKDOWN
      mistyped = control.sub("Integration: discard", "Integraton: discard")

      expect(described_class.rows(control).keys).to eq(["Relay down", "Draft discarded"])
      expect { described_class.rows(mistyped) }.to raise_error(ArgumentError, /"Draft discarded".*Integraton/)
    end

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

  describe ".missing" do
    # "a table with one row more than the given example names reports that row"
    it "missing reports exactly the one row of a three-row table that has no example" do
      markdown = <<~MD
        ### 9.3 Failure cases

        | Case | State that survives | How it is detected and repaired | Proving test |
        |---|---|---|---|
        | First case | s1 | d1 | Integration: first |
        | Second case | s2 | d2 | Concurrency: second |
        | Third case | s3 | d3 | Integration: third |

        After the table.
      MD

      rows = described_class.rows(markdown)
      missing = described_class.missing(rows, ["First case is proved", "Second case is proved"])

      expect(missing).to eq(["Third case"])
      expect(missing).to be_frozen
      expect(described_class.missing(rows, ["First case a", "Second case b", "Third case c"])).to eq([])
    end

    # "`missing` matches each example name to the longest Case text it starts with, so a short Case such as "Relay down" is never covered by an example for a longer Case that begins with it."
    it "missing credits the name Relay down extra only to the longer Case and still reports Relay down" do
      markdown = <<~MD
        ### 9.3 Failure cases

        | Case | State that survives | How it is detected and repaired | Proving test |
        |---|---|---|---|
        | Relay down | s1 | d1 | Integration: stop the relay |
        | Relay down extra | s2 | d2 | Integration: stop it longer |
      MD

      rows = described_class.rows(markdown)

      expect(described_class.missing(rows, ["Relay down extra case"])).to eq(["Relay down"])
      expect(described_class.missing(rows, ["Relay down extra case", "Relay down: projection matches"])).to eq([])
    end

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

    # "Both checks run without TIMEKEEPING_LIVE"
    it "rows and missing give the same answer on the real document with TIMEKEEPING_LIVE unset" do
      saved = ENV.fetch("TIMEKEEPING_LIVE", nil)
      ENV.delete("TIMEKEEPING_LIVE")
      begin
        rows = described_class.rows(real_document)

        expect(rows.values.count { |row| row.kind == :integration }).to eq(14)
        expect(rows.values.count { |row| row.kind == :concurrency }).to eq(1)

        covered = rows.keys - ["Relay down"]
        expect(described_class.missing(rows, covered.map { |case_text| "#{case_text} is proven" }))
          .to eq(["Relay down"])
      ensure
        saved.nil? ? ENV.delete("TIMEKEEPING_LIVE") : ENV["TIMEKEEPING_LIVE"] = saved
      end
    end
  end

  describe "the real section_9_3_spec.rb" do
    # It parses the files only, so it runs without the demo runtime; without
    # TIMEKEEPING_LIVE=1 it proves the examples are named, not that they pass.
    it "covers every Integration and Concurrency row of the real document, with TIMEKEEPING_LIVE unset" do
      source = Rails.root.join("spec/integration/timekeeping/section_9_3_spec.rb").read
      saved = ENV.fetch("TIMEKEEPING_LIVE", nil)
      ENV.delete("TIMEKEEPING_LIVE")
      begin
        rows = described_class.rows(real_document)

        expect(rows).not_to be_empty
        expect(described_class.missing(rows, TimekeepingIntegrationTags.example_names(source))).to eq([])
      ensure
        saved.nil? ? ENV.delete("TIMEKEEPING_LIVE") : ENV["TIMEKEEPING_LIVE"] = saved
      end
    end
  end
end
