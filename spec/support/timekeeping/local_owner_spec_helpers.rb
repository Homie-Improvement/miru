# frozen_string_literal: true

# Every table a Timekeeping::LocalOwner write touches. A refusal check that
# compares these counts before and after a call sees a stray row in any of
# them; a shorter list would let a leak into the missing table pass.
TIMEKEEPING_WRITE_TABLES = %w[entries entry_audits idempotency_records entry_outbox_items].freeze

# Setup the Timekeeping::LocalOwner specs share, kept in one place so a
# change to the write path's tables, ownership or roles is made once.
module TimekeepingLocalOwnerSpecHelpers
  # Counts rows by SQL rather than through models, so a row written outside
  # a model's default scope is still counted.
  def timekeeping_row_counts(tables = TIMEKEEPING_WRITE_TABLES)
    tables.index_with do |table|
      ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{table}").to_i
    end
  end

  # Puts ownership in the prepared monolith store with no handoff step, the
  # only state in which LocalOwner accepts a write.
  def prepare_local_ownership!
    ownership = TimekeepingOwnership.current
    ownership.update!(owner: "monolith", monolith_store: "prepared", handoff_step: nil)
    ownership
  end

  # Employs the user in the company with the role. Passing an existing user
  # gives one person the same role in a second company.
  def timekeeping_member(company, role, user: create(:user))
    create(:employment, company_id: company.id, user:)
    user.add_role(role, company)
    user
  end
end

RSpec.configure do |config|
  config.include TimekeepingLocalOwnerSpecHelpers
end
