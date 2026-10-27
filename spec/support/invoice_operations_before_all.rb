# frozen_string_literal: true

# `before_all` (behind `let_it_be`) pins every writing pool in one open
# transaction for the whole example group. That includes the separate pool
# InvoiceOperationsRecord writes pending intents through, so an intent would
# stay uncommitted and invisible to the invoice transaction that must settle
# it. This releases that one pool after the group's transaction begins and
# pins it again before the rollback, so the adapter's own unpin stays
# balanced. Intent rows that commit this way are removed by the cleanup in
# spec/support/database_cleaner.rb.
TestProf::BeforeAll.configure do |config|
  config.after(:begin) do
    InvoiceOperationsRecord.connection_pool.unpin_connection!
  end

  config.before(:rollback) do
    InvoiceOperationsRecord.connection_pool.pin_connection!(true)
  end
end
