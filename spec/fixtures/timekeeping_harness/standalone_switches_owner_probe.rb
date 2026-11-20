# frozen_string_literal: true

# Run by spec/meta/timekeeping_regression_spec.rb in its own rspec process. It
# loads no rails_helper and holds only a :switches_owner example, so a
# regression state run filters out everything it has. The name does not end in
# _spec.rb, so a normal suite run never loads it.
RSpec.describe "Timekeeping regression standalone switches_owner probe" do
  it "runs only in the separate switches_owner pass", :switches_owner do
    expect(true).to be(true)
  end
end
