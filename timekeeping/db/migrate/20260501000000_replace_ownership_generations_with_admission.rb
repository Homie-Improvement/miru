# frozen_string_literal: true

# docs/architecture/timekeeping-soa.md section 10.1: Timekeeping admits entry
# writes at one global generation, or at none while fenced. One row per company
# could not fence a company with no row yet, so the per-company table is
# replaced by a single row.
class ReplaceOwnershipGenerationsWithAdmission < ActiveRecord::Migration[8.1]
  def up
    # No company_id: the generation is global. id = 1 allows one row only, and
    # a null generation means fenced. The default is the initial generation, so
    # Timekeeping::Admission.ensure_initial! can build the row from defaults.
    create_table :admission do |t|
      t.bigint :generation, default: 1

      t.check_constraint "id = 1", name: "admission_single_row_check"
    end

    # The highest generation any company was admitted at, so no writer that
    # already holds it is refused after the change.
    execute <<~SQL.squish
      INSERT INTO admission (id, generation)
      SELECT 1, COALESCE(MAX(generation), 1) FROM ownership_generations
    SQL

    drop_table :ownership_generations
  end

  # The per-company generations cannot be rebuilt from one global value, and an
  # empty per-company table would let the old writer seed generation 1 again.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
