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

  describe ".request_id_tag with a UUID service token" do
    it "digests a UUID that equals the configured service token, and keeps any other UUID" do
      uuid_service_token = SecureRandom.uuid
      other_uuid = SecureRandom.uuid

      with_timekeeping_env(Timekeeping::Environment::SERVICE_TOKEN => uuid_service_token) do
        expect(described_class.request_id_tag(uuid_service_token)).to match(/\Asha256:\h{16}\z/)
        expect(described_class.request_id_tag(other_uuid)).to eq(other_uuid)
      end
    end
  end

  describe "a service token shaped like an id or a date" do
    %w[1234567890123456789 2026-01-01].each do |shaped_service_token|
      it "is masked in parameters, the query, the path and parameter values, while other ids stay clear" do
        with_timekeeping_env(Timekeeping::Environment::SERVICE_TOKEN => shaped_service_token) do
          expect(described_class.clear_param?("project_id", shaped_service_token)).to be(false)
          expect(described_class.clear_param?("from", shaped_service_token)).to be(false)
          expect(described_class.loggable_query("project_id=#{shaped_service_token}&user_id=5"))
            .to eq("project_id=[FILTERED]&user_id=5")
          expect(described_class.loggable_path("/v1/companies/#{shaped_service_token}/entries/12"))
            .to eq("/v1/companies/[FILTERED]/entries/12")
          expect(described_class.loggable_params("user_id" => shaped_service_token, "entry_ids" => ["3"]))
            .to eq("user_id" => "[FILTERED]", "entry_ids" => ["3"])
        end
      end
    end
  end

  describe "a credential configured in TIMEKEEPING_SERVICE_CREDENTIALS" do
    it "is masked even when shaped like an id, while other ids stay clear" do
      held_id = "9876543210987654321"

      with_timekeeping_env(Timekeeping::Environment::SERVICE_CREDENTIALS => "other-secret,#{held_id}") do
        expect(described_class.clear_param?("project_id", held_id)).to be(false)
        expect(described_class.clear_param?("project_id", "5")).to be(true)
        expect(described_class.loggable_path("/v1/companies/#{held_id}/entries/12"))
          .to eq("/v1/companies/[FILTERED]/entries/12")
      end
    end
  end

  describe ".loggable_method" do
    it "keeps a known HTTP method and masks any other text" do
      expect(described_class.loggable_method("GET")).to eq("GET")
      expect(described_class.loggable_method(hex_token)).to eq("[FILTERED]")
    end
  end

  describe ".loggable_query" do
    it "masks a part whose name is a credential, at the top level or in brackets under an allowed name" do
      expect(described_class.loggable_query("#{hex_token}=value&project_id=5"))
        .to eq("[FILTERED]&project_id=5")
      expect(described_class.loggable_query("project_id[#{hex_token}]=5")).to eq("[FILTERED]")
      expect(described_class.loggable_query(jwt)).to eq("[FILTERED]")
    end

    it "keeps allowed names and masks a value of the wrong shape" do
      expect(described_class.loggable_query("entry_ids[]=1&entry_ids[]=2;from=2026-01-01"))
        .to eq("entry_ids[]=1&entry_ids[]=2;from=2026-01-01")
      expect(described_class.loggable_query("project_id=#{jwt}")).to eq("project_id=[FILTERED]")
    end
  end

  describe ".loggable_params" do
    it "masks names outside the allow-list at any depth" do
      loggable = described_class.loggable_params(
        hex_token => "[FILTERED]", "project_id" => { jwt => "[FILTERED]" }, "entry_ids" => [{ jwt => "x" }, "1"]
      )

      expect(loggable).to eq(
        "[FILTERED]" => "[FILTERED]", "project_id" => { "[FILTERED]" => "[FILTERED]" },
        "entry_ids" => [{ "[FILTERED]" => "[FILTERED]" }, "1"]
      )
    end
  end

  describe ".loggable_path" do
    it "keeps route words, ids and dates, and masks every other segment" do
      expect(described_class.loggable_path("/v1/companies/12/entries/34")).to eq("/v1/companies/12/entries/34")
      expect(described_class.loggable_path("/v1/companies/#{hex_token}/entries/#{jwt}"))
        .to eq("/v1/companies/[FILTERED]/entries/[FILTERED]")
      expect(described_class.loggable_path("/v1/secret-word/")).to eq("/v1/[FILTERED]/")
    end

    it "keeps the bulk route words in clear" do
      expect(described_class.loggable_path("/v1/companies/12/entries/bulk-move")).to eq("/v1/companies/12/entries/bulk-move")
      expect(described_class.loggable_path("/v1/companies/12/entries/bulk-delete"))
        .to eq("/v1/companies/12/entries/bulk-delete")
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
