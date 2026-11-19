# frozen_string_literal: true

# The guard only parses URLs, so this spec loads the guard and its two parsers
# without rails_helper, whose schema check and cleaners need a live database.
require "active_record"
require "active_record/database_configurations"
require_relative "../support/timekeeping/timekeeping_database_reset"

RSpec.describe "TestDatabaseGuard.require_test_database_url!" do
  # "`TestDatabaseGuard.require_test_database_url!(url)` refuses
  # `postgresql://harness_selector_user@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test`"
  # "Error messages keep naming only the database, never the URL."
  # libpq reads the dbname parameter (a _test name), so this fails when only that reading is checked.
  it "refuses the selector URL by its Active Record name and keeps the URL and its credentials out of the message" do
    selector_url = "postgresql://harness_selector_user@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test"
    with_password = "postgresql://harness_selector_user:s3cret-pass@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test"

    [selector_url, with_password].each do |url|
      expect { TestDatabaseGuard.require_test_database_url!(url) }
        .to raise_error(TestDatabaseGuard::NotATestDatabase, /timekeeping_development/) { |error|
          expect(error.message).not_to include(url)
          expect(error.message).not_to include("harness_selector_user")
          expect(error.message).not_to include("s3cret-pass")
        }
    end
  end

  # "a URL whose path and dbname both end in `_test` returns nil"
  it "accepts a URL whose path and dbname both end in _test" do
    url = "postgresql://harness_user@127.0.0.1/timekeeping_live_test?dbname=timekeeping_live_test"

    expect(TestDatabaseGuard.require_test_database_url!(url)).to be_nil
  end

  # "Then require that both the libpq name and the Active Record name of the URL end in `_test`"
  # Active Record reads the path (a _test name), so this fails when only that reading is checked.
  it "refuses a URL whose path ends in _test but whose dbname names a development database" do
    url = "postgresql://harness_user@127.0.0.1/timekeeping_test?dbname=timekeeping_development"

    expect { TestDatabaseGuard.require_test_database_url!(url) }
      .to raise_error(TestDatabaseGuard::NotATestDatabase, /timekeeping_development/)
  end

  # "an unparseable URL raises and the message does not contain the URL."
  # The two URLs fail to parse in different places: an unclosed IPv6 host and a non-numeric port.
  it "refuses an unparseable URL without putting the URL or its credentials in the message" do
    [
      "postgresql://harness_user:s3cret-pass@[::1/timekeeping_test",
      "postgresql://harness_user:s3cret-pass@127.0.0.1:not-a-port/timekeeping_test"
    ].each do |url|
      expect { TestDatabaseGuard.require_test_database_url!(url) }
        .to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
          expect(error.message).not_to include(url)
          expect(error.message).not_to include("s3cret-pass")
          expect(error.message).not_to include("harness_user")
        }
    end
  end

  it "exposes the URL guard but keeps its Active Record helper private" do
    expect(TestDatabaseGuard).to respond_to(:require_test_database_url!)
    expect(TestDatabaseGuard).not_to respond_to(:active_record_database_name)
  end
end
