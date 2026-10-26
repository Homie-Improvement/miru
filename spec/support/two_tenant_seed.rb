# frozen_string_literal: true

# Loads the demo seed's two businesses, Fork & Leaf Salads and Copper Kettle
# Bakery, once for an example group tagged :two_tenant_seed. The seed is
# thousands of rows, so nothing loads at require time and the group truncates
# every table when it finishes, leaving the empty database other specs expect.
#
# The seed is loaded with the as_of recorded in the seed disposition, so the
# data matches the checked-in record.
RSpec.shared_context "two tenant seed" do
  before(:all) do
    DatabaseCleaner.clean_with :truncation, except: %w(ar_internal_metadata)
    as_of = YAML.load_file(Timekeeping::SeedDispositionRecorder::DEFAULT_PATH).fetch("as_of")
    Timekeeping::SeedDispositionRecorder.load_fresh_seed!(as_of:)
  end

  after(:all) do
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
