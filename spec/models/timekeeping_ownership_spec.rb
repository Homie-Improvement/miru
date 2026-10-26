# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimekeepingOwnership, type: :model do
  let(:connection) { ActiveRecord::Base.connection }

  def insert_ownership(values)
    connection.execute("INSERT INTO timekeeping_ownership (#{values.keys.join(', ')}) " \
      "VALUES (#{values.values.map { |value| connection.quote(value) }.join(', ')})")
  end

  describe ".current" do
    it "returns the initial record, generation 1 owned by the monolith with no handoff step" do
      ownership = described_class.current

      expect([ownership.generation, ownership.owner, ownership.handoff_step]).to eq([1, "monolith", nil])
    end

    it "raises when the record is missing instead of inventing one" do
      described_class.delete_all

      expect { described_class.current }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe ".ensure_initial!" do
    it "creates the initial record from the column defaults when the table is empty" do
      described_class.delete_all

      described_class.ensure_initial!

      expect(described_class.pluck(:generation, :owner, :handoff_step, :changed_by))
        .to eq([[1, "monolith", nil, "system"]])
    end

    it "leaves an existing record unchanged" do
      described_class.current.update!(generation: 3, owner: "timekeeping")

      described_class.ensure_initial!

      expect(described_class.pluck(:generation, :owner)).to eq([[3, "timekeeping"]])
    end
  end

  describe "database constraints" do
    it "refuses a second row" do
      expect { insert_ownership(id: 2) }.to raise_error(ActiveRecord::StatementInvalid, /single_row_check/)
    end

    it "refuses a duplicate of the one row" do
      expect { insert_ownership(id: 1) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "refuses an owner outside monolith and timekeeping" do
      expect { described_class.current.update_columns(owner: "other") }
        .to raise_error(ActiveRecord::StatementInvalid, /owner_check/)
    end

    it "refuses an unknown handoff step" do
      expect { described_class.current.update_columns(handoff_step: "bogus") }
        .to raise_error(ActiveRecord::StatementInvalid, /handoff_step_check/)
    end

    it "accepts each handoff step" do
      ownership = described_class.current

      %w[close_admission settle freeze checkpoint sequence reconcile].each do |step|
        expect { ownership.update_columns(handoff_step: step) }.not_to raise_error
      end
    end
  end

  describe "monolith_store" do
    it "starts as legacy" do
      expect(described_class.current.monolith_store).to eq("legacy")
    end

    it "refuses a store outside legacy and prepared in the database and the model" do
      ownership = described_class.current
      ownership.monolith_store = "other"

      expect(ownership).not_to be_valid
      expect { ownership.update_columns(monolith_store: "other") }
        .to raise_error(ActiveRecord::StatementInvalid, /monolith_store_check/)
    end
  end

  describe "#snapshot_generation_accepted?" do
    let(:ownership) { described_class.current }

    it "accepts the current generation with or without a handoff" do
      ownership.update_columns(generation: 2, handoff_step: nil, final_outbox_position: nil)
      expect(ownership.snapshot_generation_accepted?(generation: 2, outbox_position: 1)).to be(true)

      ownership.update_columns(handoff_step: "freeze", final_outbox_position: 10)
      expect(ownership.snapshot_generation_accepted?(generation: 2, outbox_position: 50)).to be(true)
    end

    it "accepts the previous generation during a handoff only up to the final outbox position, and not after the flip" do
      ownership.update_columns(generation: 2, handoff_step: "freeze", final_outbox_position: 10)

      # "It accepts a snapshot whose `generation` is the current owner's. During a handoff, between closing
      # admission and the ownership flip, it also accepts the outgoing owner's previous-generation snapshots,
      # but only up to the final outbox position captured when that owner was frozen. The flip removes that permission."
      expect(ownership.snapshot_generation_accepted?(generation: 2, outbox_position: 99)).to be(true)
      expect(ownership.snapshot_generation_accepted?(generation: 1, outbox_position: 10)).to be(true)
      expect(ownership.snapshot_generation_accepted?(generation: 1, outbox_position: 11)).to be(false)
      expect(ownership.snapshot_generation_accepted?(generation: 0, outbox_position: 1)).to be(false)
      expect(ownership.snapshot_generation_accepted?(generation: 3, outbox_position: 1)).to be(false)

      ownership.update_columns(final_outbox_position: nil)
      expect(ownership.snapshot_generation_accepted?(generation: 1, outbox_position: 1)).to be(false)

      ownership.update_columns(handoff_step: nil, final_outbox_position: 10)
      expect(ownership.snapshot_generation_accepted?(generation: 1, outbox_position: 5)).to be(false)
      expect(ownership.snapshot_generation_accepted?(generation: 2, outbox_position: 5)).to be(true)
    end

    it "refuses a previous-generation snapshot whose outbox position is not an integer" do
      ownership.update_columns(generation: 2, handoff_step: "freeze", final_outbox_position: 10)

      [nil, "5", 5.0].each do |position|
        expect(ownership.snapshot_generation_accepted?(generation: 1, outbox_position: position)).to be(false)
      end
    end

    it "refuses the previous generation at every handoff step until this handoff's position is stored" do
      ownership.update_columns(generation: 3, final_outbox_position: nil)

      TimekeepingOwnership::HANDOFF_STEPS.each do |step|
        ownership.update_columns(handoff_step: step)
        expect(ownership.snapshot_generation_accepted?(generation: 2, outbox_position: 5)).to be(false)
      end

      ownership.update_columns(final_outbox_position: 10)
      TimekeepingOwnership::HANDOFF_STEPS.each do |step|
        ownership.update_columns(handoff_step: step)
        expect(ownership.snapshot_generation_accepted?(generation: 2, outbox_position: 5)).to be(true)
      end
    end

    it "refuses an older generation at any outbox position" do
      ownership.update_columns(generation: 3, handoff_step: "freeze", final_outbox_position: 10)

      [0, 1, 10].each do |position|
        expect(ownership.snapshot_generation_accepted?(generation: 1, outbox_position: position)).to be(false)
      end
    end
  end

  describe "validations" do
    it "rejects an unknown owner and handoff step" do
      ownership = described_class.current
      ownership.assign_attributes(owner: "other", handoff_step: "bogus")

      expect(ownership).not_to be_valid
      expect(ownership.errors.attribute_names).to contain_exactly(:owner, :handoff_step)
    end
  end
end

# Generated by Descant: acceptance tests below.
RSpec.describe TimekeepingOwnership, type: :model do
  # "Freeze: stop applying commit and abort, capture the final outbox position P, and drain the outbox into the projection through P."
  # "`handoff_step` is written only after a step's own work has committed."
  # The drain runs while the row still records 'settle', so the stored P alone must open the previous generation.
  it "accepts previous-generation snapshots up to the stored final outbox position before freeze is recorded" do
    ownership = described_class.new(generation: 3, owner: "timekeeping", handoff_step: "settle",
                                    final_outbox_position: 40, monolith_store: "prepared")

    expect(ownership.snapshot_generation_accepted?(generation: 2, outbox_position: 40)).to be(true)
    expect(ownership.snapshot_generation_accepted?(generation: 2, outbox_position: 41)).to be(false)
    expect(ownership.snapshot_generation_accepted?(generation: 1, outbox_position: 1)).to be(false)
  end
end

RSpec.describe TimekeepingOwnership, type: :model do
  # Step 1 clears the stored position, so a position left from an earlier handoff never opens the previous
  # generation; the flip and abort end the permission by clearing handoff_step.
  it "refuses previous-generation snapshots while no final outbox position is stored or no handoff is in progress" do
    settling_without_position = described_class.new(generation: 3, owner: "timekeeping", handoff_step: "settle",
                                                     final_outbox_position: nil, monolith_store: "prepared")
    idle_with_old_position = described_class.new(generation: 3, owner: "timekeeping", handoff_step: nil,
                                                 final_outbox_position: 40, monolith_store: "prepared")

    expect(settling_without_position.snapshot_generation_accepted?(generation: 2, outbox_position: 1)).to be(false)
    expect(idle_with_old_position.snapshot_generation_accepted?(generation: 2, outbox_position: 1)).to be(false)
    expect(idle_with_old_position.snapshot_generation_accepted?(generation: 3, outbox_position: 99)).to be(true)
  end
end

RSpec.describe TimekeepingOwnership, type: :model do
  # "The source is legacy, and pre-flight and reservation derivation run, exactly while it is null."
  # "The generation is not used for this."
  it "reads the legacy source from legacy_retired_at and never from the generation" do
    initial = described_class.current
    aborted_first_cutover = described_class.new(generation: 3, owner: "monolith", monolith_store: "legacy",
                                                legacy_retired_at: nil)
    retired = described_class.new(generation: 2, owner: "timekeeping", monolith_store: "prepared",
                                  legacy_retired_at: Time.utc(2026, 11, 1, 12))

    expect(initial.legacy_retired_at).to be_nil
    expect(initial.source_legacy?).to be(true)
    expect(aborted_first_cutover.source_legacy?).to be(true)
    expect(retired.source_legacy?).to be(false)
  end
end

RSpec.describe TimekeepingOwnership, type: :model do
  let(:ownership) { described_class.current }

  it "accepts the previous generation up to a stored final outbox position while settle is still the recorded step" do
    # "Freeze: stop applying commit and abort, capture the final outbox position P, and drain the outbox into the projection through P."
    # The drain runs before 'freeze' is recorded, so the stored P must already open the permission.
    ownership.update_columns(generation: 3, handoff_step: "settle", final_outbox_position: 40)

    expect(ownership.snapshot_generation_accepted?(generation: 2, outbox_position: 40)).to be(true)
    expect(ownership.snapshot_generation_accepted?(generation: 2, outbox_position: 41)).to be(false)
    expect(ownership.snapshot_generation_accepted?(generation: 1, outbox_position: 1)).to be(false)

    ownership.update_columns(final_outbox_position: nil)
    expect(ownership.snapshot_generation_accepted?(generation: 2, outbox_position: 1)).to be(false)

    ownership.update_columns(handoff_step: nil, final_outbox_position: 40)
    expect(ownership.snapshot_generation_accepted?(generation: 2, outbox_position: 1)).to be(false)
  end
end

RSpec.describe TimekeepingOwnership, type: :model do
  let(:ownership) { described_class.current }

  it "source_legacy? follows legacy_retired_at and never the generation" do
    # "The source is legacy, and pre-flight and reservation derivation run, exactly while it is null."
    # "The generation is not used for this."
    expect(ownership.legacy_retired_at).to be_nil
    expect(ownership.source_legacy?).to be(true)

    ownership.update_columns(generation: 3)
    expect(ownership.reload.source_legacy?).to be(true)

    ownership.update_columns(legacy_retired_at: Time.zone.parse("2026-11-01 12:00"))
    expect(ownership.reload.source_legacy?).to be(false)

    ownership.update_columns(generation: 2)
    expect(ownership.reload.source_legacy?).to be(false)
  end
end

RSpec.describe TimekeepingOwnership, type: :model do
  # Scenario: freeze stores P while handoff_step is still 'settle', then drains. If acceptance still waits
  # for a recorded 'freeze', the drain is refused and the handoff can never finish.
  # "`handoff_step` is written only after a step's own work has committed."
  it "lets the freeze drain deliver previous-generation snapshots up to the stored P before freeze is recorded" do
    ownership = described_class.current
    ownership.update_columns(generation: 3, handoff_step: "settle", final_outbox_position: 40)

    expect(ownership.snapshot_generation_accepted?(generation: 2, outbox_position: 40)).to be(true)
    expect(ownership.snapshot_generation_accepted?(generation: 2, outbox_position: 41)).to be(false)

    # Step 1 clears P, so before this handoff stores its own P nothing of generation 2 is accepted.
    ownership.update_columns(final_outbox_position: nil)
    expect(ownership.snapshot_generation_accepted?(generation: 2, outbox_position: 1)).to be(false)

    # The flip and abort clear handoff_step, which ends the permission even with P still stored.
    ownership.update_columns(handoff_step: nil, final_outbox_position: 40)
    expect(ownership.snapshot_generation_accepted?(generation: 2, outbox_position: 1)).to be(false)
  end
end

RSpec.describe TimekeepingOwnership, type: :model do
  # "An aborted handoff, which leaves the legacy store at a raised generation, counts as begun; disclose this choice in the pull request."
  it "unless_handoff_begun skips the block and persists nothing at legacy generation 2 but runs and persists it in the initial state" do
    company_baseline = Company.count

    described_class.current.update_columns(generation: 2, handoff_step: nil, owner: "monolith", monolith_store: "legacy")
    refused = described_class.unless_handoff_begun { create(:company) }

    expect(refused).to be(false)
    expect(Company.count).to eq(company_baseline)

    described_class.current.update_columns(generation: 1)
    admitted = described_class.unless_handoff_begun { create(:company) }

    expect(admitted).to be(true)
    expect(Company.count).to eq(company_baseline + 1)
  end

  # "It is true when any of these holds: `generation > 1`, `handoff_step` is set,
  # `owner` is not `monolith`, `monolith_store` is not `legacy`"
  it "handoff_begun? is false only for the initial row and true when any single column leaves it" do
    ownership = described_class.current
    expect([ownership.generation, ownership.handoff_step, ownership.owner, ownership.monolith_store])
      .to eq([1, nil, "monolith", "legacy"])
    expect(ownership.handoff_begun?).to be(false)

    {
      generation: 2,
      handoff_step: "settle",
      owner: "timekeeping",
      monolith_store: "prepared"
    }.each do |column, value|
      ownership.update_columns(generation: 1, handoff_step: nil, owner: "monolith", monolith_store: "legacy")
      ownership.update_columns(column => value)

      expect(ownership.reload.handoff_begun?).to be(true), "expected #{column}=#{value.inspect} to count as begun"
    end
  end

  # "A missing ownership row counts as begun."
  it "the class-level handoff_begun? treats a missing row as begun without creating it" do
    expect(described_class.handoff_begun?).to be(false)

    described_class.delete_all

    expect(described_class.handoff_begun?).to be(true)
    expect(described_class.count).to eq(0)
  end

  # "A refused run or request writes nothing."
  it "unless_handoff_begun runs its block only in the initial legacy state" do
    runs = 0

    expect(described_class.unless_handoff_begun { runs += 1 }).to be(true)
    expect(runs).to eq(1)

    described_class.current.update_columns(owner: "timekeeping")
    expect(described_class.unless_handoff_begun { runs += 1 }).to be(false)

    described_class.delete_all
    expect(described_class.unless_handoff_begun { runs += 1 }).to be(false)

    expect(runs).to eq(1)
    expect(described_class.count).to eq(0)
  end

  it "refuse_if_handoff_begun! raises in each begun state, after the flip and after a rollback, and returns nil in the initial row" do
    ownership = described_class.current
    initial = { generation: 1, handoff_step: nil, owner: "monolith", monolith_store: "legacy" }
    ownership.update_columns(initial)

    # "Seed and demo builders are refused before their first write once a handoff has begun, including after a flip and after a rollback"
    expect(described_class.refuse_if_handoff_begun!).to be_nil

    begun_states = [
      { handoff_step: "settle" },
      { generation: 2, owner: "timekeeping" },
      { generation: 2, monolith_store: "prepared" },
      { generation: 2 }
    ]
    begun_states.each do |changes|
      ownership.update_columns(initial.merge(changes))
      expect { described_class.refuse_if_handoff_begun! }
        .to raise_error(TimekeepingOwnership::HandoffBegun), "expected #{changes} to refuse"
    end
  end

  # "`handoff_step` alone is not enough, because the flip clears it. An aborted handoff, which leaves
  # the legacy store at a raised generation, counts as begun; disclose this choice in the pull request."
  it "still counts as begun after the flip or an abort has cleared handoff_step" do
    ownership = described_class.current

    ownership.update_columns(generation: 2, handoff_step: nil, owner: "timekeeping", monolith_store: "legacy")
    expect(ownership.reload.handoff_begun?).to be(true)

    ownership.update_columns(generation: 3, handoff_step: nil, owner: "monolith", monolith_store: "legacy")
    expect(ownership.reload.handoff_begun?).to be(true)

    ownership.update_columns(generation: 1, handoff_step: nil, owner: "monolith", monolith_store: "legacy")
    expect(ownership.reload.handoff_begun?).to be(false)
  end
end
