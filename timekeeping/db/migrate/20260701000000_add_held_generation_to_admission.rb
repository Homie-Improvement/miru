# frozen_string_literal: true

# A first cutover writes its correction snapshots while Timekeeping is still
# fenced, before the handoff has flipped ownership to it. Delivered then, they
# would change the monolith's legacy rows that a resumed handoff must read
# unchanged. held_generation names the one generation whose outbox rows the
# relay holds back until Timekeeping admits that generation; null holds none.
class AddHeldGenerationToAdmission < ActiveRecord::Migration[8.1]
  def change
    add_column :admission, :held_generation, :bigint
  end
end
