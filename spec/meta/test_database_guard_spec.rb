# frozen_string_literal: true

require "rails_helper"

# The collector probe and the live Timekeeping instance hand URLs to processes that write rows, so
# neither may reach a database that is not a test database. Active Record reads the URL's path;
# libpq, which PG.connect uses for the reset and the probe's rows, reads its dbname parameter.
RSpec.describe TestDatabaseGuard, ".require_test_database_url!" do
  it "is public" do
    expect(described_class.public_methods).to include(:require_test_database_url!)
  end

  it "has moved out of IntegratedRuntime with its active_record_database_name helper" do
    # "IntegratedRuntime no longer defines `require_test_database_url!` or `active_record_database_name` and calls the TestDatabaseGuard method instead"
    expect(IntegratedRuntime.respond_to?(:require_test_database_url!, true)).to be(false)
    expect(IntegratedRuntime.respond_to?(:active_record_database_name, true)).to be(false)
  end

  it "returns nil for a URL that names a _test database under both readings" do
    url = "postgresql://collector_guard_user@127.0.0.1/timekeeping_collector_guard_test"

    expect(described_class.require_test_database_url!(url)).to be_nil
  end

  it "returns nil for a URL whose path and dbname name different databases that both end in _test" do
    url = "postgresql://collector_guard_user@127.0.0.1/timekeeping_path_guard_test?dbname=timekeeping_dbname_guard_test"

    expect(described_class.require_test_database_url!(url)).to be_nil
  end

  it "refuses a URL whose path names a non-test database" do
    expect { described_class.require_test_database_url!("postgres://localhost:5432/timekeeping_collector_rows_demo") }
      .to raise_error(TestDatabaseGuard::NotATestDatabase)
  end

  it "refuses a URL whose path names a non-test database behind a _test dbname parameter" do
    # "`TestDatabaseGuard.require_test_database_url!(url)` refuses `postgresql://harness_selector_user@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test`"
    url = "postgresql://harness_selector_user@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test"

    expect { described_class.require_test_database_url!(url) }
      .to raise_error(TestDatabaseGuard::NotATestDatabase, /timekeeping_development/)
  end

  it "refuses a URL whose dbname parameter names a non-test database behind a _test path" do
    url = "postgresql://collector_guard_user@127.0.0.1/timekeeping_collector_guard_test?dbname=timekeeping_production"

    expect { described_class.require_test_database_url!(url) }
      .to raise_error(TestDatabaseGuard::NotATestDatabase, /timekeeping_production/)
  end

  it "refuses an unparseable URL without echoing its user, password or text in the message" do
    # "Error messages keep naming only the database, never the URL."
    # Built from parts so the fixture keeps its dummy user and password in the committed file.
    user = "leak_user"
    password = "s3cret_pw"
    ["@[bad/x", "@[bad-host/leak_guard_db"].each do |rest|
      url = "postgresql://" + user + ":" + password + rest

      expect { described_class.require_test_database_url!(url) }.to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
        expect(error.message).not_to include(user)
        expect(error.message).not_to include(password)
        expect(error.message).not_to include(url)
      }
    end
  end
end
