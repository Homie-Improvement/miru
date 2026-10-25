# frozen_string_literal: true

# A row here is what locks an entry against billing changes. The table has no
# id column: a reservation is identified by its company, entry and state.
class Reservation < ApplicationRecord
end
