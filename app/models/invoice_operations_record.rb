# frozen_string_literal: true

# Same database as ApplicationRecord, but its own connection pool. A pending
# invoice operation intent is written through it so it commits on its own,
# before the reservation store is asked to prepare, and survives a rollback
# of the invoice transaction that is still open on the main connection.
class InvoiceOperationsRecord < ApplicationRecord
  self.abstract_class = true

  establish_connection(ApplicationRecord.connection_db_config)
end
