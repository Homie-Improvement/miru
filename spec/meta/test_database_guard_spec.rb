# frozen_string_literal: true

require "rails_helper"

RSpec.describe TestDatabaseGuard do
  context "more tests 10" do
    it "refuses the issue's URL whose Active Record path names a non-test database behind a _test dbname" do
      # "`TestDatabaseGuard.require_test_database_url!(url)` refuses `postgresql://harness_selector_user@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test` and accepts a URL whose libpq and Active Record names both end in \_test"
      url = "postgresql://harness_selector_user@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test"

      expect { described_class.require_test_database_url!(url) }
        .to raise_error(TestDatabaseGuard::NotATestDatabase, /timekeeping_development/)
    end
  end

  context "more tests 12" do
    it "refuses an unparseable URL without echoing its user, password or text in the error message" do
      # "Error messages keep naming only the database, never the URL."
      url = "postgresql://[REDACTED:db-connection-string]@[bad/x"

      expect { described_class.require_test_database_url!(url) }
        .to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
          expect(error.message).not_to include("leak_user")
          expect(error.message).not_to include("s3cret_pw")
          expect(error.message).not_to include(url)
        }
    end
  end

  context "more tests 15", ".require_test_database_url! accepted URL" do
    # "a URL whose path and dbname both end in `_test` returns nil"
    it "returns nil for a URL whose path and dbname both end in _test" do
      url = "postgresql://collector_guard_user@127.0.0.1/timekeeping_path_guard_test?dbname=timekeeping_dbname_guard_test"

      expect(described_class.require_test_database_url!(url)).to be_nil
    end
  end

  context "more tests 16", ".require_test_database_url! unparseable URL" do
    # "an unparseable URL raises and the message does not contain the URL"
    # "Error messages keep naming only the database, never the URL."
    it "refuses an unparseable URL without putting the URL or its credentials in the message" do
      url = "postgresql://[REDACTED:db-connection-string]@[bad/x"

      expect { described_class.require_test_database_url!(url) }
        .to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
          expect(error.message).not_to include(url)
          expect(error.message).not_to include("leak_user")
          expect(error.message).not_to include("s3cret_pw")
        }
    end
  end

  context "more tests 20" do
    # "Error messages keep naming only the database, never the URL."
    it "refuses an unparseable URL without echoing its user, password or text in the message" do
      url = "postgresql://[REDACTED:db-connection-string]@[bad/x"

      expect { described_class.require_test_database_url!(url) }.to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
        expect(error.message).not_to include("leak_user")
        expect(error.message).not_to include("s3cret_pw")
        expect(error.message).not_to include(url)
      }
    end
  end

  context "more tests 21" do
    # "IntegratedRuntime no longer defines `require_test_database_url!` or `active_record_database_name` and calls the TestDatabaseGuard method instead"
    it "IntegratedRuntime defines neither require_test_database_url! nor active_record_database_name after the move" do
      expect(IntegratedRuntime.respond_to?(:require_test_database_url!, true)).to be(false)
      expect(IntegratedRuntime.respond_to?(:active_record_database_name, true)).to be(false)
      expect(described_class).to respond_to(:require_test_database_url!)
    end
  end

  # Moved from spec/lib/timekeeping_demo/integrated_runtime_spec.rb with the guard itself.
  # The collector probe writes rows that break the queue rule on purpose, so it must never reach a
  # database that is not a test database. Active Record reads the URL's path; libpq, which PG.connect
  # uses to insert and delete the probe's rows, reads its dbname parameter.
  describe ".require_test_database_url! for the collector probe" do
    it "is public" do
      expect(described_class.public_methods).to include(:require_test_database_url!)
    end

    it "returns nil for a URL that names a _test database under both readings" do
      url = "postgresql://collector_guard_user@127.0.0.1/timekeeping_collector_guard_test"

      expect(described_class.require_test_database_url!(url)).to be_nil
    end

    it "refuses a URL whose path names a non-test database" do
      expect { described_class.require_test_database_url!("postgres://localhost:5432/timekeeping_collector_rows_demo") }
        .to raise_error(TestDatabaseGuard::NotATestDatabase)
    end

    it "refuses a URL whose path names a non-test database behind a _test dbname parameter" do
      url = "postgresql://collector_guard_user@127.0.0.1/timekeeping_development?dbname=timekeeping_collector_guard_test"

      expect { described_class.require_test_database_url!(url) }
        .to raise_error(TestDatabaseGuard::NotATestDatabase, /timekeeping_development/)
    end

    it "refuses a URL whose dbname parameter names a non-test database behind a _test path" do
      url = "postgresql://collector_guard_user@127.0.0.1/timekeeping_collector_guard_test?dbname=timekeeping_production"

      expect { described_class.require_test_database_url!(url) }
        .to raise_error(TestDatabaseGuard::NotATestDatabase, /timekeeping_production/)
    end
  end

  context "more tests 23", ".require_test_database_url! malformed input" do
    # "Error messages keep naming only the database, never the URL."
    it "refuses an unparseable URL without echoing its user, password or text" do
      url = "postgresql://[REDACTED:db-connection-string]@[bad-host/leak_guard_db"

      expect { described_class.require_test_database_url!(url) }.to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
        expect(error.message).not_to include("leak_guard_user")
        expect(error.message).not_to include("s3cret_guard_pw")
        expect(error.message).not_to include(url)
      }
    end
  end
end
