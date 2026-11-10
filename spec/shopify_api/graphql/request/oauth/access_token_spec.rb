# frozen_string_literal: true

RSpec.describe ShopifyAPI::GraphQL::Request::OAuth::AccessToken do

  def client(options = nil)
    described_class.new(
      ENV.fetch("SHOPIFY_CLIENT_API_KEY"),
      ENV.fetch("SHOPIFY_CLIENT_API_SECRET"),
      ENV.fetch("SHOPIFY_DOMAIN"),
      options
    )
  end
  alias_method :access_token, :client

  def non_expiring_token
    ENV.fetch("SHOPIFY_TOKEN")
  end

  def refresh_token
    ENV.fetch("SHOPIFY_REFRESH_TOKEN", "<SHOPIFY_REFRESH_TOKEN>")
  end

  describe ".new" do
    it "requires a client ID" do
      expect {
        described_class.new(nil, ENV.fetch("SHOPIFY_CLIENT_API_SECRET"), ENV.fetch("SHOPIFY_DOMAIN"))
      }.to raise_error(ArgumentError, "client_id required")
    end

    it "requires a non-blank client ID" do
      expect {
        described_class.new(" ", ENV.fetch("SHOPIFY_CLIENT_API_SECRET"), ENV.fetch("SHOPIFY_DOMAIN"))
      }.to raise_error(ArgumentError, "client_id required")
    end

    it "requires a client secret" do
      expect {
        described_class.new(ENV.fetch("SHOPIFY_CLIENT_API_KEY"), nil, ENV.fetch("SHOPIFY_DOMAIN"))
      }.to raise_error(ArgumentError, "client_secret required")
    end

    it "requires a shop" do
      expect {
        described_class.new(ENV.fetch("SHOPIFY_CLIENT_API_KEY"), ENV.fetch("SHOPIFY_CLIENT_API_SECRET"), nil)
      }.to raise_error(ArgumentError, "shop required")
    end
  end

  describe "#migrate", :vcr do
    context "with a valid non-expiring token" do
      it "successfully migrates to an expiring offline access token and can query the API" do
        result = client.migrate(non_expiring_token)

        warn "New migration result: #{result.inspect}" if VCR.current_cassette.recording?

        expect(result).to be_a(Hash)
        expect(result["access_token"]).to be_a(String)
        expect(result["access_token"]).not_to be_empty
        expect(result["refresh_token"]).to be_a(String)
        expect(result["refresh_token"]).not_to be_empty
        expect(result["expires_in"]).to be_a(Integer)
        expect(result["expires_in"]).to be > 0
        expect(result["scope"]).to be_a(String)

        graphql = ShopifyAPI::GraphQL::Request.new(ENV.fetch("SHOPIFY_DOMAIN"), result["access_token"])
        response = nil

        expect {
          response = graphql.execute("{ shop { name } }")
        }.to_not raise_error

        expect(response.dig(:data, :shop, :name)).to be_a(String)
      end
    end

    context "with an invalid token" do
      it "raises InvalidTokenError" do
        expect {
          client.migrate("invalid_token_12345")
        }.to raise_error(described_class::InvalidTokenError)
      end
    end

    context "when response returns invalid_requested_token_type" do
      it "raises InvalidTokenError" do
        response = Net::HTTPResponse::CODE_TO_OBJ["400"].new("1.1", "400", "Bad Request")
        body = { "error" => "invalid_requested_token_type", "error_description" => "Invalid requested token type" }

        expect {
          client.send(:handle_error, response, body)
        }.to raise_error(described_class::InvalidTokenError)
      end
    end

    context "when token is missing or blank" do
      it "raises an ArgumentError for nil token" do
        expect {
          client.migrate(nil)
        }.to raise_error(ArgumentError, "token required")
      end

      it "raises an ArgumentError for blank token" do
        expect {
          client.migrate("   ")
        }.to raise_error(ArgumentError, "token required")
      end
    end
  end

  describe "#refresh", :vcr do
    it "refreshes an expiring offline access token" do
      result = client.refresh(refresh_token)

      warn "New refresh result: #{result.inspect}" if VCR.current_cassette.recording?

      expect(result).to be_a(Hash)
      expect(result["access_token"]).to be_a(String)
      expect(result["access_token"]).not_to be_empty
      expect(result["refresh_token"]).to be_a(String)
      expect(result["refresh_token"]).not_to be_empty
      expect(result["expires_in"]).to be_a(Integer)
      expect(result["expires_in"]).to be > 0
      expect(result["scope"]).to be_a(String)

      graphql = ShopifyAPI::GraphQL::Request.new(ENV.fetch("SHOPIFY_DOMAIN"), result["access_token"])
      response = nil

      expect {
        response = graphql.execute("{ shop { name } }")
      }.to_not raise_error

      expect(response.dig(:data, :shop, :name)).to be_a(String)
      expect(response.dig(:data, :shop, :name)).not_to be_empty
    end
    context "when token is missing or blank" do
      it "raises an ArgumentError for nil token" do
        expect {
          client.refresh(nil)
        }.to raise_error(ArgumentError, "refresh token required")
      end

      it "raises an ArgumentError for blank token" do
        expect {
          client.refresh("   ")
        }.to raise_error(ArgumentError, "refresh token required")
      end
    end

    context "with an invalid refresh token" do
      it "raises InvalidRefreshTokenError" do
        expect {
          client.refresh("invalid_refresh_token_12345")
        }.to raise_error(described_class::InvalidRefreshTokenError)
      end
    end
  end
end
