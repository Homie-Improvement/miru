# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::SeedDisposition do
  let(:as_of) { "2026-10-23" }
  let(:classification) do
    Timekeeping::Preflight::LISTS.index_with { [] }.merge(
      unlocked_links: [
        { entry_id: 12, invoice_id: 2 },
        { entry_id: 3, invoice_id: 1 },
        { entry_id: 11, invoice_id: 2 }
      ]
    )
  end
  let(:by_company) do
    {
      "Zeta Co" => { classification:, invoice_numbers: { 1 => "Z-0001", 2 => "Z-0002" } },
      "Alpha Co" => {
        classification: Timekeeping::Preflight::LISTS.index_with { [] }.merge(unlocked_links: [{ entry_id: 7, invoice_id: 9 }]),
        invoice_numbers: { 9 => "A-0001" }
      }
    }
  end
  let(:recorded) { described_class.record(by_company, as_of:) }

  describe ".record" do
    it "lists each invoice with unlocked links under its company, sorted, every one reserved" do
      expect(recorded).to eq(
        "as_of" => "2026-10-23",
        "companies" => {
          "Alpha Co" => { "A-0001" => { "entry_ids" => [7], "disposition" => "reserve" } },
          "Zeta Co" => {
            "Z-0001" => { "entry_ids" => [3], "disposition" => "reserve" },
            "Z-0002" => { "entry_ids" => [11, 12], "disposition" => "reserve" }
          }
        }
      )
      expect(recorded["companies"].keys).to eq(["Alpha Co", "Zeta Co"])
    end

    it "gives the same YAML for the same input and holds no time of generation" do
      yaml = YAML.dump(recorded)

      expect(YAML.dump(described_class.record(by_company.to_a.reverse.to_h, as_of:))).to eq(yaml)
      expect(yaml.scan(/\d{4}-\d{2}-\d{2}/)).to eq(["2026-10-23"])
    end

    it "lists a company with no unlocked links with no invoices" do
      empty = { "Quiet Co" => { classification: Timekeeping::Preflight::LISTS.index_with { [] }, invoice_numbers: {} } }

      expect(described_class.record(empty, as_of:)["companies"]).to eq("Quiet Co" => {})
    end
  end

  describe ".verify" do
    let(:live) { recorded.deep_dup }

    it "reports no problem when the recorded and live dispositions are equal" do
      expect(described_class.verify(recorded:, live:)).to eq([])
    end

    it "fails an empty recorded list" do
      empty = { "as_of" => as_of, "companies" => { "Alpha Co" => {}, "Zeta Co" => {} } }

      expect(described_class.verify(recorded: empty, live: empty)).to include("the recorded seed disposition lists no invoices")
    end

    it "fails a recorded list with an entry id added by hand" do
      edited = recorded.deep_dup
      edited["companies"]["Zeta Co"]["Z-0001"]["entry_ids"] << 4

      expect(described_class.verify(recorded: edited, live:))
        .to eq(["Zeta Co Z-0001: recorded entry ids [3, 4], live [3]"])
    end

    it "fails a recorded list with an entry id removed by hand" do
      edited = recorded.deep_dup
      edited["companies"]["Zeta Co"]["Z-0002"]["entry_ids"] = [11]

      expect(described_class.verify(recorded: edited, live:))
        .to eq(["Zeta Co Z-0002: recorded entry ids [11], live [11, 12]"])
    end

    it "fails a recorded invoice whose disposition was flipped to none" do
      edited = recorded.deep_dup
      edited["companies"]["Alpha Co"]["A-0001"]["disposition"] = "none"

      expect(described_class.verify(recorded: edited, live:))
        .to include('Alpha Co A-0001: disposition "none", expected "reserve"')
    end

    it "fails when the seed changes one link" do
      changed_seed = live.deep_dup
      changed_seed["companies"]["Zeta Co"]["Z-0003"] = { "entry_ids" => [20], "disposition" => "reserve" }

      expect(described_class.verify(recorded:, live: changed_seed))
        .to eq(["Zeta Co Z-0003: recorded entry ids nil, live [20]"])
    end

    it "fails a listing filed under the other company" do
      edited = recorded.deep_dup
      edited["companies"]["Zeta Co"]["A-0001"] = edited["companies"]["Alpha Co"].delete("A-0001")

      expect(described_class.verify(recorded: edited, live:)).to contain_exactly(
        "Alpha Co A-0001: recorded entry ids nil, live [7]",
        "Zeta Co A-0001: recorded entry ids [7], live nil"
      )
    end

    it "fails a recorded list generated with a different as_of" do
      edited = recorded.merge("as_of" => "2026-01-01")

      expect(described_class.verify(recorded: edited, live:))
        .to eq(['recorded as_of "2026-01-01" differs from live "2026-10-23"'])
    end
  end
end
