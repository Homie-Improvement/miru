# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimekeepingSection93Traceability do
  context "more tests 2" do
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
  end

  context "more tests 3" do
    # "Count the two kinds separately, not as a total of 15, so a Contract row parsed as Integration still fails."
    it "rows on the real document finds exactly 14 integration rows and 1 concurrency row" do
      rows = described_class.rows(Rails.root.join("docs/architecture/timekeeping-soa.md").read)

      expect(rows).to be_frozen
      expect(rows.values.count { |row| row.kind == :integration }).to eq(14)
      expect(rows.values.count { |row| row.kind == :concurrency }).to eq(1)
      expect(rows.select { |_, row| row.kind == :concurrency }.keys).to eq(["Two invoices prepare one entry at once"])
      expect(rows.keys).to include("Prepare answer lost (timeout or 5xx)")
    end
  end

  context "more tests 4" do
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
  end

  context "more tests 5" do
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
  end

  context "more tests 6" do
    # "Read only that table and stop at the first non-table line, so another table with a Proving test column elsewhere in the document is never counted."
    it "rows keeps raw Case text, leaves out Contract rows and never reads a second table" do
      header = "| Case | State that survives | How it is detected and repaired | Proving test |\n|---|---|---|---|\n"
      markdown = +"### 9.3 Failure cases\n\n#{header}"
      markdown << "| Prepare answer lost (timeout or 5xx) | intent `failed` | abort | Integration: drop the answer |\n"
      markdown << "| Refused: `on_another_invoice` | Integration: not here | d | Contract: 409 |\n"
      markdown << "| Two invoices prepare one entry at once | one | lock | Concurrency: parallel |\n"
      markdown << "\nA paragraph ends the table.\n\n#{header}| Elsewhere case | s | d | Integration: other |\n"

      rows = described_class.rows(markdown)

      expect(rows.keys).to eq(["Prepare answer lost (timeout or 5xx)", "Two invoices prepare one entry at once"])
      row = rows.fetch("Prepare answer lost (timeout or 5xx)")
      expect(row.kind).to eq(:integration)
      expect(row.survives).to eq("intent `failed`")
      expect(row.proving_test).to eq("Integration: drop the answer")
      expect([row, row.case_text, row.survives, row.proving_test]).to all(be_frozen)
    end
  end

  context "more tests 7" do
    # "Both checks run without TIMEKEEPING_LIVE"
    it "rows and missing give the same answer on the real document with TIMEKEEPING_LIVE unset" do
      saved = ENV.fetch("TIMEKEEPING_LIVE", nil)
      ENV.delete("TIMEKEEPING_LIVE")
      begin
        markdown = Rails.root.join("docs/architecture/timekeeping-soa.md").read
        rows = described_class.rows(markdown)

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
end
