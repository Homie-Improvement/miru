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

    it "refuses a previous-generation snapshot whose outbox position is not an integer" do
      ownership.update_columns(generation: 2, handoff_step: "freeze", final_outbox_position: 10)

      [nil, "5", 5.0].each do |position|
        expect(ownership.snapshot_generation_accepted?(generation: 1, outbox_position: position)).to be(false)
      end
    end

    it "refuses the previous generation before this handoff's freeze, even with a position left from an earlier handoff" do
      ownership.update_columns(generation: 3, final_outbox_position: 10)

      %w[close_admission settle].each do |step|
        ownership.update_columns(handoff_step: step)
        expect(ownership.snapshot_generation_accepted?(generation: 2, outbox_position: 5)).to be(false)
      end

      %w[freeze checkpoint sequence reconcile].each do |step|
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
  it "accepts the previous generation during a handoff only up to the final outbox position, and not after the flip" do
    ownership = described_class.current
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
end
