# frozen_string_literal: true

require "rails_helper"

RSpec.describe "TestDatabaseGuard.require_test_database_url!" do
  context "more tests 10" do
    # "Error messages keep naming only the database, never the URL."
    it "require_test_database_url! refuses an unparseable URL without putting the URL or its password in the error message" do
      url = "postgresql://harness_user:s3cret-pass@[::1/timekeeping_test"

      expect { TestDatabaseGuard.require_test_database_url!(url) }
        .to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
          expect(error.message).not_to include(url)
          expect(error.message).not_to include("s3cret-pass")
          expect(error.message).not_to include("harness_user")
        }
    end
  end

  context "more tests 11" do
    # "`TestDatabaseGuard.require_test_database_url!(url)` refuses
    # `postgresql://harness_selector_user@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test`"
    # "Error messages keep naming only the database, never the URL."
    it "require_test_database_url! refuses the selector URL by its Active Record name and keeps the password out of the message" do
      url = "postgresql://harness_selector_user:s3cret-pass@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test"

      expect { TestDatabaseGuard.require_test_database_url!(url) }
        .to raise_error(TestDatabaseGuard::NotATestDatabase, /timekeeping_development/) { |error|
          expect(error.message).not_to include("s3cret-pass")
          expect(error.message).not_to include("harness_selector_user")
          expect(error.message).not_to include(url)
        }
    end
  end

  context "more tests 12" do
    # "`TestDatabaseGuard.require_test_database_url!(url)` refuses
    # `postgresql://harness_selector_user@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test`
    # and accepts a URL whose libpq and Active Record names both end in \_test"
    # libpq reads the dbname parameter (a _test name), so this example fails when only that reading is checked.
    it "refuses the selector URL whose path names timekeeping_development behind a _test dbname" do
      url = "postgresql://harness_selector_user@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test"

      expect { TestDatabaseGuard.require_test_database_url!(url) }
        .to raise_error(TestDatabaseGuard::NotATestDatabase, /timekeeping_development/)
    end
  end

  context "more tests 13" do
    # "a URL whose path and dbname both end in `_test` returns nil"
    it "accepts a URL whose path and dbname both end in _test" do
      url = "postgresql://harness_user@127.0.0.1/timekeeping_live_test?dbname=timekeeping_live_test"

      expect(TestDatabaseGuard.require_test_database_url!(url)).to be_nil
    end
  end

  context "more tests 14" do
    # "Then require that both the libpq name and the Active Record name of the URL end in `_test`"
    # Active Record reads the path (a _test name), so this example fails when only that reading is checked.
    it "refuses a URL whose path ends in _test but whose dbname names a development database" do
      url = "postgresql://harness_user@127.0.0.1/timekeeping_test?dbname=timekeeping_development"

      expect { TestDatabaseGuard.require_test_database_url!(url) }
        .to raise_error(TestDatabaseGuard::NotATestDatabase, /timekeeping_development/)
    end
  end

  context "more tests 15" do
    # "an unparseable URL raises and the message does not contain the URL."
    # "Error messages keep naming only the database, never the URL."
    it "refuses an unparseable URL without putting the URL or its password in the message" do
      url = "postgresql://harness_user:s3cret-pass@127.0.0.1:not-a-port/timekeeping_test"
      error = nil

      begin
        TestDatabaseGuard.require_test_database_url!(url)
      rescue TestDatabaseGuard::NotATestDatabase => e
        error = e
      end

      expect(error).to be_a(TestDatabaseGuard::NotATestDatabase)
      expect(error.message).not_to include(url)
      expect(error.message).not_to include("s3cret-pass")
      expect(error.message).not_to include("harness_user")
    end
  end

  context "more tests 16" do
    # "IntegratedRuntime no longer defines `require_test_database_url!` or `active_record_database_name`
    # and calls the TestDatabaseGuard method instead"
    it "IntegratedRuntime no longer defines the URL guard or its Active Record helper" do
      expect(IntegratedRuntime.respond_to?(:require_test_database_url!, true)).to be(false)
      expect(IntegratedRuntime.respond_to?(:active_record_database_name, true)).to be(false)
      expect(TestDatabaseGuard).to respond_to(:require_test_database_url!)
      expect(TestDatabaseGuard).not_to respond_to(:active_record_database_name)
    end
  end

  context "more tests 17" do
    # "`TestDatabaseGuard.require_test_database_url!(url)` refuses `postgresql://harness_selector_user@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test` and accepts a URL whose libpq and Active Record names both end in \_test"
    # "Error messages keep naming only the database, never the URL."
    # libpq reads the dbname parameter (a _test name) while Active Record reads the path, so a
    # libpq-only check would let db:prepare migrate timekeeping_development.
    it "refuses a development path hidden behind a _test dbname and keeps the password out of the message" do
      url = "postgresql://harness_selector_user:s3cret-pass@127.0.0.1/timekeeping_development?dbname=timekeeping_selector_test"

      expect { TestDatabaseGuard.require_test_database_url!(url) }
        .to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
          expect(error.message).to include("timekeeping_development")
          expect(error.message).not_to include("s3cret-pass")
          expect(error.message).not_to include(url)
        }
    end
  end

  context "more tests 18" do
    # "Then require that both the libpq name and the Active Record name of the URL end in `_test`"
    # The mirror of the selector vector: an Active Record-only check would pass this URL while the
    # libpq reset empties timekeeping_development.
    it "refuses a _test path whose dbname parameter names a development database" do
      url = "postgresql://harness_selector_user@127.0.0.1/timekeeping_selector_test?dbname=timekeeping_development"

      expect { TestDatabaseGuard.require_test_database_url!(url) }
        .to raise_error(TestDatabaseGuard::NotATestDatabase, /timekeeping_development/)
    end
  end

  context "more tests 19" do
    # "an unparseable URL raises and the message does not contain the URL."
    # A reading that cannot be parsed must be refused, never skipped.
    it "refuses an unparseable URL without echoing it or its password" do
      url = "postgresql://harness_user:s3cret-pass@[::1/timekeeping_test"

      expect { TestDatabaseGuard.require_test_database_url!(url) }
        .to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
          expect(error.message).not_to include(url)
          expect(error.message).not_to include("s3cret-pass")
        }
    end
  end

  context "more tests 20" do
    # "IntegratedRuntime no longer defines `require_test_database_url!` or `active_record_database_name` and calls the TestDatabaseGuard method instead"
    # A private copy left behind would let the two guards drift apart.
    it "leaves no copy of the URL guard or its helper on IntegratedRuntime" do
      expect(IntegratedRuntime.respond_to?(:require_test_database_url!, true)).to be(false)
      expect(IntegratedRuntime.respond_to?(:active_record_database_name, true)).to be(false)
      expect(TestDatabaseGuard).to respond_to(:require_test_database_url!)
    end
  end
end
