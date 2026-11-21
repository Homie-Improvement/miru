# frozen_string_literal: true

require "rails_helper"

# Runs the real cutover, rollback and re-cutover against the local demo
# runtime and proves each seeded company's invoice money is unchanged by them.
# All three handoffs share one example, because the runtime hooks empty the
# monolith after every example. It needs TIMEKEEPING_LIVE=1, so the default
# suite skips it, and a skip is not a pass.
RSpec.describe "Timekeeping money guard" do
  context "more tests 2", :integrated_runtime, :two_tenant_seed, committed_data: true, owner_state: "legacy" do
    it "keeps each seeded company's invoice money equal to its pre-cutover baseline across cutover, rollback and re-cutover, and reports a one-cent change" do
      company_ids = [fork_and_leaf.id, copper_kettle.id]
      # "Use `Timekeeping::FinancialSnapshot.take(company_id:)` and `.compare` once for each company, never a combined total."
      baselines = company_ids.index_with { |id| Timekeeping::FinancialSnapshot.take(company_id: id) }
      # "Each baseline must hold invoice values."
      baselines.each do |id, baseline|
        expect(baseline.fetch(:values).keys.map(&:first)).to include(:invoice), "company #{id} baseline holds no invoice"
      end

      with_live_handoff_integrations(@integrated_runtime) do
        %i[cutover rollback re_cutover].each do |direction|
          run_live_handoff(direction, company_ids:)
          # "Compare every later snapshot with the one taken before the first cutover, with exact equality."
          company_ids.each do |id|
            later = Timekeeping::FinancialSnapshot.take(company_id: id)
            expect(Timekeeping::FinancialSnapshot.compare(baselines.fetch(id), later)).to eq([]), "#{direction}, company #{id}"
          end
        end
      end

      # "Add a negative control: a one-cent change between snapshots is reported."
      # The PDF totals do not print outstanding_amount, so the stored value is
      # the only key the change moves.
      baseline, key = baselines.each_value.lazy.filter_map do |snapshot|
        found = snapshot.fetch(:values).keys.find { |kind, _id, field| kind == :invoice && field == :outstanding_amount }
        [snapshot, found] if found
      end.first
      old_value = baseline.fetch(:values).fetch(key)
      new_value = old_value + BigDecimal("0.01")
      changed = baseline.merge(values: baseline.fetch(:values).merge(key => new_value))

      expect(Timekeeping::FinancialSnapshot.compare(baseline, changed)).to eq([
        Timekeeping::FinancialSnapshot::Difference.new(
          company_id: baseline.fetch(:company_id), kind: :invoice, record_id: key[1], field: :outstanding_amount,
          old_value:, new_value:
        )
      ])
      expect(baseline.fetch(:values).fetch(key)).to eq(old_value)
    end
  end

  context "more tests 3", :integrated_runtime, :two_tenant_seed, committed_data: true, owner_state: "legacy" do
    include LiveHandoff::ExampleHelpers

    # "A test takes the financial snapshot of section 10.4 before and after the first cutover, a rollback and a re-cutover, with no user billing edit between them, and fails on any difference."
    # "Compare every later snapshot with the one taken before the first cutover, with exact equality."
    it "money stays equal to each company's own pre-cutover baseline and a one-cent outstanding change is the only difference" do
      company_ids = [fork_and_leaf.id, copper_kettle.id].sort
      baselines = company_ids.index_with { |id| Timekeeping::FinancialSnapshot.take(company_id: id) }

      # "Each baseline must hold invoice values."
      baselines.each_value do |baseline|
        expect(baseline.fetch(:values).keys.map(&:first)).to include(:invoice)
      end

      with_live_handoff_integrations(@integrated_runtime) do
        %i[cutover rollback re_cutover].each do |direction|
          run_live_handoff(direction, company_ids:)
          company_ids.each do |id|
            later = Timekeeping::FinancialSnapshot.take(company_id: id)
            expect(Timekeeping::FinancialSnapshot.compare(baselines.fetch(id), later)).to eq([]), "#{direction} #{id}"
          end
        end
      end

      # "Add a negative control: a one-cent change between snapshots is reported."
      baseline = baselines.fetch(company_ids.first)
      key = baseline.fetch(:values).keys.find { |kind, _id, field| kind == :invoice && field == :outstanding_amount }
      old_value = baseline.fetch(:values).fetch(key)
      altered = baseline.merge(values: baseline.fetch(:values).merge(key => old_value + BigDecimal("0.01")))

      expect(Timekeeping::FinancialSnapshot.compare(baseline, altered)).to eq([
        Timekeeping::FinancialSnapshot::Difference.new(
          company_id: company_ids.first, kind: :invoice, record_id: key[1], field: :outstanding_amount,
          old_value:, new_value: old_value + BigDecimal("0.01")
        )
      ])
      expect(baseline.fetch(:values).fetch(key)).to eq(old_value)
    end
  end
end
