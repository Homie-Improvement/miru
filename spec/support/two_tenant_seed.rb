# frozen_string_literal: true

# Loads the demo seed's two businesses, Fork & Leaf Salads and Copper Kettle
# Bakery, once for an example group tagged :two_tenant_seed. The seed is
# thousands of rows, so nothing loads at require time and the group truncates
# every table when it finishes, leaving the empty database other specs expect.
#
# The seed is loaded with the as_of recorded in the seed disposition, so the
# data matches the checked-in record. Only the first load in a test process
# runs db/seeds.rb; later loads restore the copy TestDatabaseCleanup.seed_captures
# holds, with the same rows, ids and sequence values.
#
# The load here is skipped when every example the group runs is a seeded
# committed example: the committed_data hook in spec/support/database_cleaner.rb
# deletes every table and loads the seed again before each of those, so a load
# here is wasted. The check is per example because an example or nested group
# can turn committed_data off, and that example still needs this load.
RSpec.shared_context "two tenant seed" do
  before(:all) do
    examples = self.class.descendant_filtered_examples
    next if examples.all? { |example| TestDatabaseCleanup.seeded_committed?(example.metadata) }

    TestDatabaseCleanup.before_reset!
    DatabaseCleaner.clean_with :truncation, except: %w(ar_internal_metadata)
    Timekeeping::SeedDispositionRecorder.load_fresh_seed!(
      as_of: TestDatabaseCleanup.seed_as_of, captures: TestDatabaseCleanup.seed_captures
    )
  end

  after(:all) do
    TestDatabaseCleanup.before_reset!
    DatabaseCleaner.clean_with :truncation, except: %w(ar_internal_metadata)
    # Truncation empties the ownership table; restore its one row, as the
    # suite setup in spec/support/database_cleaner.rb does, so later specs find it.
    TimekeepingOwnership.ensure_initial!
  end

  let(:fork_and_leaf) { Company.find_by!(name: "Fork & Leaf Salads") }
  let(:copper_kettle) { Company.find_by!(name: "Copper Kettle Bakery") }
end

RSpec.configure do |config|
  config.include_context "two tenant seed", :two_tenant_seed
end
