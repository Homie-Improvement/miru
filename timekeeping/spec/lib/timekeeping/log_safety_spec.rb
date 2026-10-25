# frozen_string_literal: true

require "rails_helper"

RSpec.describe Timekeeping::LogSafety do
  let(:jwt) { mint_token }
  let(:hex_token) { SecureRandom.hex(32) }

  describe ".clear_param?" do
    it "masks a credential sent under an allowed id name" do
      expect(described_class.clear_param?("project_id", jwt)).to be(false)
      expect(described_class.clear_param?("project_id", hex_token)).to be(false)
    end

    it "keeps an integer id in clear" do
      expect(described_class.clear_param?("project_id", "5")).to be(true)
      expect(described_class.clear_param?(:entry_id, 42)).to be(true)
    end

    it "keeps only a plain date in clear for date names" do
      expect(described_class.clear_param?("from", "2026-01-01T00:00:00Z")).to be(false)
      expect(described_class.clear_param?("from", "2026-01-01")).to be(true)
    end

    it "never keeps a name outside the allow-list in clear" do
      expect(described_class.clear_param?("note", "5")).to be(false)
      expect(described_class.clear_param?("proof_url", "2026-01-01")).to be(false)
    end
  end

  describe ".request_id_tag" do
    it "keeps a UUID" do
      uuid = SecureRandom.uuid

      expect(described_class.request_id_tag(uuid)).to eq(uuid)
    end

    it "logs any other value as a stable digest that hides it" do
      tag = described_class.request_id_tag(hex_token)

      expect(tag).to match(/\Asha256:\h{16}\z/)
      expect(tag).not_to include(hex_token)
      expect(described_class.request_id_tag(hex_token)).to eq(tag)
    end
  end

  describe ".loggable_path" do
    it "keeps route words, ids and dates, and masks every other segment" do
      expect(described_class.loggable_path("/v1/companies/12/entries/34")).to eq("/v1/companies/12/entries/34")
      expect(described_class.loggable_path("/v1/companies/#{hex_token}/entries/#{jwt}"))
        .to eq("/v1/companies/[FILTERED]/entries/[FILTERED]")
      expect(described_class.loggable_path("/v1/secret-word/")).to eq("/v1/[FILTERED]/")
    end
  end

  describe "the application's parameter filter" do
    def filter(params)
      ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(params)
    end

    it "masks a token under an allowed name, a disallowed name and inside metadata" do
      filtered = filter(
        "project_id" => jwt,
        "note" => jwt,
        "proof_url" => "https://example.test/#{jwt}",
        "source_metadata" => { "token" => jwt },
        "entry_ids" => [jwt]
      )

      expect(filtered.to_s).not_to include(jwt)
      expect(filtered).to include(
        "project_id" => "[FILTERED]", "note" => "[FILTERED]", "proof_url" => "[FILTERED]",
        "source_metadata" => "[FILTERED]", "entry_ids" => ["[FILTERED]"]
      )
    end

    it "keeps ordinary ids and dates readable" do
      filtered = filter("project_id" => "5", "entry_ids" => %w[1 2], "from" => "2026-01-01", "user_id" => 7)

      expect(filtered).to eq("project_id" => "5", "entry_ids" => %w[1 2], "from" => "2026-01-01", "user_id" => 7)
    end
  end
end
