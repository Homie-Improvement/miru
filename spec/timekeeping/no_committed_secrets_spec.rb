# frozen_string_literal: true

require "rails_helper"
require "open3"

# The Timekeeping token keys and service token are secrets and never sit in a
# checked-in file. This scan reads every tracked (or new, not ignored) file as
# raw bytes, so neither file size nor encoding lets a secret through.
#
# The patterns are assembled from fragments so this file holds no text they
# match.
module TimekeepingCommittedSecrets
  DASHES = "-" * 5
  SECRET_KEYS = %w[TIMEKEEPING_TOKEN_PRIVATE_KEY TIMEKEEPING_SERVICE_TOKEN].freeze
  KEY = "(?:#{SECRET_KEYS.join("|")})"
  # A value that is a reference rather than a literal starts with one of these:
  # an ERB tag, a shell or YAML interpolation, or nothing at all.
  LITERAL_START = %q|[^\s"'$<{#]|

  PATTERNS = {
    pem_private_key: "#{DASHES}BEGIN (?:[A-Z]+ )?PRIVATE KEY#{DASHES}",
    # A KEY=value line in an env file or shell script, with or without export.
    env_file_value: "^[ \\t]*(?:export[ \\t]+)?#{KEY}[ \\t]*=[ \\t]*[\"']?#{LITERAL_START}",
    # A KEY: value line in YAML.
    yaml_value: "^[ \\t]*#{KEY}[ \\t]*:[ \\t]*[\"']?#{LITERAL_START}",
    # A quoted string assigned to the key in Ruby (ENV[...] = or a hash pair).
    quoted_assignment: "#{KEY}[\"']?\\]?[ \\t]*(?:=>|=|:)[ \\t]*[\"']#{LITERAL_START}",
    # A quoted default passed beside the key, as in ENV.fetch(KEY, default).
    quoted_default: "#{KEY}[\"'][ \\t]*,[ \\t]*[\"']#{LITERAL_START}"
  }.transform_values { |source| Regexp.new(source.b) }.freeze

  def self.findings(bytes)
    data = bytes.b
    PATTERNS.select { |_name, pattern| pattern.match?(data) }.keys
  end

  def self.tracked_files
    output, status = Open3.capture2("git", "ls-files", "-z", "--cached", "--others", "--exclude-standard",
      chdir: Rails.root.to_s)
    raise "git ls-files failed" unless status.success?

    output.split("\0").select { |path| File.file?(Rails.root.join(path)) && !File.symlink?(Rails.root.join(path)) }
  end
end

RSpec.describe "No committed Timekeeping secrets" do
  let(:service_key) { "TIMEKEEPING_SERVICE_TOKEN" }
  let(:private_key_name) { "TIMEKEEPING_TOKEN_PRIVATE_KEY" }

  delegate :findings, to: TimekeepingCommittedSecrets

  describe "the matcher" do
    it "flags a generated PEM private key" do
      expect(findings(OpenSSL::PKey::RSA.generate(2048).to_pem)).to include(:pem_private_key)
    end

    it "flags a literal value in an env file" do
      expect(findings("#{service_key}=abc123\n")).to include(:env_file_value)
      expect(findings("export #{private_key_name}='abc'\n")).to include(:env_file_value)
    end

    it "flags a quoted literal assigned in Ruby" do
      expect(findings(%(ENV["#{private_key_name}"] = "x"\n))).to include(:quoted_assignment)
      expect(findings(%(ENV.fetch("#{service_key}", "x")\n))).to include(:quoted_default)
    end

    it "flags a literal value in YAML" do
      expect(findings("  #{service_key}: abc123\n")).to include(:yaml_value)
    end

    it "flags a secret placed after more than 1 MiB of padding" do
      padded = ("a" * (1024 * 1024 + 10)) + "\n#{service_key}=abc123\n"

      expect(findings(padded)).to include(:env_file_value)
    end

    it "flags a private key beside bytes that are not valid UTF-8" do
      sample = "\xFF\xFE\x00".b + OpenSSL::PKey::RSA.generate(2048).to_pem.b

      expect(sample.dup.force_encoding("UTF-8")).not_to be_valid_encoding
      expect(findings(sample)).to include(:pem_private_key)
    end

    it "does not flag values that read the secret from somewhere else" do
      expect(findings(%(ENV["#{service_key}"] = SecureRandom.hex(32)\n))).to be_empty
      expect(findings(%(#{service_key}=<%= ENV["#{service_key}"] %>\n))).to be_empty
      expect(findings("#{service_key}=\n")).to be_empty
      expect(findings("#{service_key}=${#{service_key}}\n")).to be_empty
    end

    it "does not flag the key names as the architecture doc writes them" do
      doc = File.binread(Rails.root.join("docs/architecture/timekeeping-soa.md"))

      expect(doc).to include(service_key)
      expect(findings(doc)).to be_empty
    end

    it "does not flag this spec file" do
      expect(findings(File.binread(__FILE__))).to be_empty
    end
  end

  it "finds no PEM private key or literal Timekeeping secret in any tracked file" do
    files = TimekeepingCommittedSecrets.tracked_files
    expect(files).to include("spec/timekeeping/no_committed_secrets_spec.rb", "Gemfile")

    offenders = files.filter_map do |path|
      found = TimekeepingCommittedSecrets.findings(File.binread(Rails.root.join(path)))
      "#{path}: #{found.join(", ")}" if found.any?
    end

    expect(offenders).to be_empty
  end
end
