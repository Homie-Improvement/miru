# frozen_string_literal: true

require "rails_helper"

RSpec.describe OmniauthFullHost do
  let(:initializer_path) { Rails.root.join("config/initializers/omniauth_full_host.rb").to_s }

  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    example.run
  ensure
    ENV["APP_BASE_URL"] = original_app_base_url
    OmniAuth.config.full_host = original_full_host
  end

  describe ".resolve" do
    it "uses the per-environment fallback when APP_BASE_URL is nil, empty or whitespace" do
      [nil, "", "   "].each do |unset_value|
        expect(described_class.resolve(app_base_url: unset_value, fallback: "http://example.com"))
          .to eq("http://example.com")
      end
    end

    it "keeps a non-blank APP_BASE_URL ahead of the fallback and drops its trailing slash" do
      expect(described_class.resolve(app_base_url: "https://app.miru.so", fallback: "http://example.com"))
        .to eq("https://app.miru.so")
      expect(described_class.resolve(app_base_url: "https://app.miru.so/", fallback: "http://example.com"))
        .to eq("https://app.miru.so")
    end

    # The per-environment value is required: a missing one must not leave OmniAuth
    # building the host from the request.
    it "refuses to resolve when both APP_BASE_URL and the required fallback are missing or blank" do
      [nil, "", "  ", "   "].each do |missing_fallback|
        expect { described_class.resolve(app_base_url: nil, fallback: missing_fallback) }
          .to raise_error(OmniauthFullHost::InvalidBaseUrl)
      end
    end

    it "refuses a base URL that is not an absolute http or https URL with a host" do
      ["example.com", "ftp://example.com", "http://"].each do |malformed|
        expect { described_class.resolve(app_base_url: malformed, fallback: "http://example.com") }
          .to raise_error(OmniauthFullHost::InvalidBaseUrl)
        expect { described_class.resolve(app_base_url: nil, fallback: malformed) }
          .to raise_error(OmniauthFullHost::InvalidBaseUrl)
      end
    end
  end

  describe ".pin!" do
    it "pins full_host to the fixed string rather than a callable that reads the request" do
      described_class.pin!("http://example.com")

      expect(OmniAuth.config.full_host).to eq("http://example.com")
      expect(OmniAuth.config.full_host).not_to respond_to(:call)
    end
  end

  describe "the initializer at boot" do
    it "declares the required default base URL for the test environment" do
      expect(Rails.configuration.x.default_base_url).to eq("http://example.com")
    end

    # A String, not a callable, means nothing on the pin path can read the request's headers.
    it "pins full_host to the environment's declared base URL as a fixed string when APP_BASE_URL is unset" do
      ENV.delete("APP_BASE_URL")
      OmniAuth.config.full_host = nil

      load initializer_path

      expect(OmniAuth.config.full_host).to be_a(String)
      expect(OmniAuth.config.full_host).to eq(Rails.configuration.x.default_base_url)
    end

    # The test environment declares the same host the specs expect, so this swaps in a
    # distinct value to show the initializer reads the setting rather than a literal.
    it "takes the fallback from config.x.default_base_url rather than a fixed value" do
      original_default_base_url = Rails.configuration.x.default_base_url
      ENV.delete("APP_BASE_URL")
      Rails.configuration.x.default_base_url = "https://boot-check.test"

      load initializer_path

      expect(OmniAuth.config.full_host).to eq("https://boot-check.test")
    ensure
      Rails.configuration.x.default_base_url = original_default_base_url
    end

    # A malformed value must stop boot: a relative or hostless full_host would let OmniAuth
    # fill in request-derived parts.
    it "refuses to boot on an APP_BASE_URL with no scheme instead of leaving full_host to the request" do
      ENV["APP_BASE_URL"] = "example.com"
      OmniAuth.config.full_host = nil

      expect { load initializer_path }.to raise_error(OmniauthFullHost::InvalidBaseUrl)
    end
  end
end

RSpec.describe OmniauthFullHost do
  let(:initializer_path) { Rails.root.join("config/initializers/omniauth_full_host.rb").to_s }

  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    example.run
  ensure
    ENV["APP_BASE_URL"] = original_app_base_url
    OmniAuth.config.full_host = original_full_host
  end

  # "Either production boot raises on an http​:// APP_BASE_URL (checked by a spec), or a recorded decision says plain http is allowed in production."
  it "refuses to boot in production on an http APP_BASE_URL and accepts an https one" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))

    ENV["APP_BASE_URL"] = "http://app.miru.so"
    OmniAuth.config.full_host = nil
    expect { load initializer_path }.to raise_error(OmniauthFullHost::InvalidBaseUrl)
    expect(OmniAuth.config.full_host).to be_nil

    ENV["APP_BASE_URL"] = "https://app.miru.so"
    load initializer_path
    expect(OmniAuth.config.full_host).to eq("https://app.miru.so")
  end
end

RSpec.describe OmniauthFullHost do
  it "requires https from either source only when require_https is set" do
    expect { described_class.resolve(app_base_url: "http://app.miru.so", fallback: "https://fallback.test", require_https: true) }
      .to raise_error(OmniauthFullHost::InvalidBaseUrl)
    expect { described_class.resolve(app_base_url: nil, fallback: "http://example.com", require_https: true) }
      .to raise_error(OmniauthFullHost::InvalidBaseUrl)
    expect(described_class.resolve(app_base_url: "https://app.miru.so/", fallback: "http://example.com", require_https: true))
      .to eq("https://app.miru.so")

    # Outside production the http local defaults must keep working.
    expect(described_class.resolve(app_base_url: "http://app.miru.so", fallback: "http://example.com"))
      .to eq("http://app.miru.so")
    expect(described_class.resolve(app_base_url: "http://app.miru.so", fallback: "http://example.com", require_https: false))
      .to eq("http://app.miru.so")
  end
end

RSpec.describe OmniauthFullHost do
  # Boot errors reach deploy logs, and APP_BASE_URL is stored as a deploy secret.
  it "keeps credentials embedded in a refused http base URL out of the error message" do
    expect {
      described_class.resolve(app_base_url: "http://deploy-user:s3cr3t-token@app.miru.so", fallback: "https://fallback.test", require_https: true)
    }.to raise_error(OmniauthFullHost::InvalidBaseUrl) { |error|
      expect(error.message).not_to include("s3cr3t-token")
      expect(error.message).to include("APP_BASE_URL")
    }
  end
end

RSpec.describe OmniauthFullHost do
  let(:initializer_path) { Rails.root.join("config/initializers/omniauth_full_host.rb").to_s }

  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    example.run
  ensure
    ENV["APP_BASE_URL"] = original_app_base_url
    OmniAuth.config.full_host = original_full_host
  end

  # "Either production boot raises on an http​:// APP_BASE_URL (checked by a spec), or a recorded decision says plain http is allowed in production."
  it "refuses to boot in production on an http APP_BASE_URL" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
    ENV["APP_BASE_URL"] = "http://app.miru.so"
    OmniAuth.config.full_host = nil

    expect { load initializer_path }.to raise_error(OmniauthFullHost::InvalidBaseUrl)
    expect(OmniAuth.config.full_host).to be_nil
  end
end

RSpec.describe OmniauthFullHost do
  let(:initializer_path) { Rails.root.join("config/initializers/omniauth_full_host.rb").to_s }

  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    example.run
  ensure
    ENV["APP_BASE_URL"] = original_app_base_url
    OmniAuth.config.full_host = original_full_host
  end

  # The https rule is production-only: the test environment keeps accepting http.
  it "boots in production on an https APP_BASE_URL and still boots in test on an http one" do
    ENV["APP_BASE_URL"] = "http://app.miru.so"
    load initializer_path
    expect(OmniAuth.config.full_host).to eq("http://app.miru.so")

    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
    ENV["APP_BASE_URL"] = "https://app.miru.so/"
    load initializer_path
    expect(OmniAuth.config.full_host).to eq("https://app.miru.so")
  end
end

RSpec.describe OmniauthFullHost do
  it "resolve with require_https refuses an http base URL from either source without echoing its credentials" do
    expect { described_class.resolve(app_base_url: "http://app.miru.so", fallback: "https://x.test", require_https: true) }
      .to raise_error(OmniauthFullHost::InvalidBaseUrl)
    expect { described_class.resolve(app_base_url: nil, fallback: "http://example.com", require_https: true) }
      .to raise_error(OmniauthFullHost::InvalidBaseUrl)
    expect { described_class.resolve(app_base_url: "http://user:secret@app.miru.so", fallback: "https://x.test", require_https: true) }
      .to raise_error(OmniauthFullHost::InvalidBaseUrl) { |error| expect(error.message).not_to include("secret") }

    expect(described_class.resolve(app_base_url: "https://app.miru.so", fallback: "http://example.com", require_https: true))
      .to eq("https://app.miru.so")
    expect(described_class.resolve(app_base_url: "http://app.miru.so", fallback: "http://example.com"))
      .to eq("http://app.miru.so")
  end
end

RSpec.describe OmniauthFullHost do
  let(:initializer_path) { Rails.root.join("config/initializers/omniauth_full_host.rb").to_s }

  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    example.run
  ensure
    ENV["APP_BASE_URL"] = original_app_base_url
    OmniAuth.config.full_host = original_full_host
  end

  # The production rule must refuse only plain http, not https.
  it "boots in production on an https APP_BASE_URL and pins it as full_host" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
    ENV["APP_BASE_URL"] = "https://app.miru.so/"
    OmniAuth.config.full_host = nil

    expect { load initializer_path }.not_to raise_error
    expect(OmniAuth.config.full_host).to eq("https://app.miru.so")
  end
end

RSpec.describe OmniauthFullHost do
  it "resolve with require_https refuses an http base URL from APP_BASE_URL or the fallback and accepts https" do
    expect { described_class.resolve(app_base_url: "http://app.miru.so", fallback: "https://fallback.test", require_https: true) }
      .to raise_error(OmniauthFullHost::InvalidBaseUrl)
    expect { described_class.resolve(app_base_url: nil, fallback: "http://example.com", require_https: true) }
      .to raise_error(OmniauthFullHost::InvalidBaseUrl)
    expect { described_class.resolve(app_base_url: "ftp://app.miru.so", fallback: "https://fallback.test", require_https: true) }
      .to raise_error(OmniauthFullHost::InvalidBaseUrl)

    expect(described_class.resolve(app_base_url: "https://app.miru.so", fallback: "http://example.com", require_https: true))
      .to eq("https://app.miru.so")
    expect(described_class.resolve(app_base_url: "  ", fallback: "https://fallback.test/", require_https: true))
      .to eq("https://fallback.test")
  end
end

RSpec.describe OmniauthFullHost do
  # Development and test keep their plain-http local defaults; only production requires https.
  it "resolve keeps accepting http base URLs when require_https is false or omitted" do
    expect(described_class.resolve(app_base_url: "http://app.miru.so", fallback: "http://example.com"))
      .to eq("http://app.miru.so")
    expect(described_class.resolve(app_base_url: "http://app.miru.so", fallback: "http://example.com", require_https: false))
      .to eq("http://app.miru.so")
    expect(described_class.resolve(app_base_url: nil, fallback: "http://localhost:3000", require_https: false))
      .to eq("http://localhost:3000")
  end
end

RSpec.describe OmniauthFullHost do
  # The refusal reaches boot logs, so a password embedded in the URL must not appear in it.
  it "resolve with require_https names the source but not URL credentials when refusing http" do
    expect { described_class.resolve(app_base_url: "http://user:s3cret-pass@app.miru.so", fallback: "https://fallback.test", require_https: true) }
      .to raise_error(OmniauthFullHost::InvalidBaseUrl) { |error|
        expect(error.message).to include("APP_BASE_URL")
        expect(error.message).not_to include("s3cret-pass")
      }
  end
end

RSpec.describe OmniauthFullHost do
  let(:initializer_path) { Rails.root.join("config/initializers/omniauth_full_host.rb").to_s }

  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    original_default_base_url = Rails.configuration.x.default_base_url
    example.run
  ensure
    ENV["APP_BASE_URL"] = original_app_base_url
    OmniAuth.config.full_host = original_full_host
    Rails.configuration.x.default_base_url = original_default_base_url
  end

  # Acceptance: "Either production boot raises on an http​:// APP_BASE_URL (checked by a spec), or a
  # recorded decision says plain http is allowed in production."
  # An unset APP_BASE_URL must not route around the rule through an http fallback.
  it "refuses to boot production on an http fallback when APP_BASE_URL is unset, leaving full_host unpinned" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
    ENV.delete("APP_BASE_URL")
    Rails.configuration.x.default_base_url = "http://fallback-check.test"
    OmniAuth.config.full_host = nil

    expect { load initializer_path }.to raise_error(OmniauthFullHost::InvalidBaseUrl)
    expect(OmniAuth.config.full_host).to be_nil
  end
end

RSpec.describe OmniauthFullHost do
  let(:initializer_path) { Rails.root.join("config/initializers/omniauth_full_host.rb").to_s }

  around do |example|
    original_app_base_url = ENV["APP_BASE_URL"]
    original_full_host = OmniAuth.config.full_host
    example.run
  ensure
    ENV["APP_BASE_URL"] = original_app_base_url
    OmniAuth.config.full_host = original_full_host
  end

  # Acceptance: "Either production boot raises on an http​:// APP_BASE_URL (checked by a spec), or a
  # recorded decision says plain http is allowed in production."
  # A silent upgrade to https would hide the misconfiguration, so boot must raise and pin nothing.
  it "refuses to boot production on an http APP_BASE_URL instead of rewriting it to https" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
    ENV["APP_BASE_URL"] = "http://app.miru.so"
    OmniAuth.config.full_host = nil

    expect { load initializer_path }.to raise_error(OmniauthFullHost::InvalidBaseUrl)
    expect(OmniAuth.config.full_host).to be_nil
  end
end

RSpec.describe OmniauthFullHost do
  # Acceptance: "Either production boot raises on an http​:// APP_BASE_URL (checked by a spec), or a
  # recorded decision says plain http is allowed in production."
  # The boot error lands in deploy logs, so a credential in the URL must not appear in it.
  it "refuses an http base URL with embedded credentials under require_https without echoing the password" do
    expect {
      described_class.resolve(
        app_base_url: "http://user:secret@app.miru.so",
        fallback: "https://fallback.test",
        require_https: true
      )
    }.to raise_error(OmniauthFullHost::InvalidBaseUrl) { |error| expect(error.message).not_to include("secret") }
  end
end

RSpec.describe OmniauthFullHost do
  # Acceptance: "Either production boot raises on an http​:// APP_BASE_URL (checked by a spec), or a
  # recorded decision says plain http is allowed in production."
  # Letter case or padding must not become a way around the https rule.
  it "refuses non-https schemes with a host, including an upper-case HTTP, under require_https" do
    ["HTTP://app.miru.so", "  http://app.miru.so/  ", "ftp://app.miru.so"].each do |non_https|
      expect {
        described_class.resolve(app_base_url: non_https, fallback: "https://fallback.test", require_https: true)
      }.to raise_error(OmniauthFullHost::InvalidBaseUrl)
    end
  end
end
