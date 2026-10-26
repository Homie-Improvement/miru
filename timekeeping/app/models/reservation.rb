# frozen_string_literal: true

# A row here is what locks an entry against billing changes. The table has no
# id column: a reservation is identified by its company, entry and state.
#
# Select an operation's rows by invoice_operation_id, never by operation_id
# alone: operation ids are unique only per company and service, and rows with
# no owning operation carry an operation_id nothing checks.
class Reservation < ApplicationRecord
end
