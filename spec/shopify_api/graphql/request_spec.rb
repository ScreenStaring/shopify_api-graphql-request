# frozen_string_literal: true

RSpec.describe ShopifyAPI::GraphQL::Request do
  def client(options = {})
    described_class.new(ENV.fetch("SHOPIFY_DOMAIN"), ENV.fetch("SHOPIFY_TOKEN"), options)
  end

  describe "#execute" do
    describe "queries" do
      it "executes queries" do
        result = client.execute(<<-GQL)
          query {
            shop {
              domains {
                host
              }
            }
          }
        GQL

        hosts = result.dig(:data, :shop, :domains).map { |d| d[:host] }
        expect(hosts).to include(ENV["SHOPIFY_DOMAIN"])
      end

      it "executes queries with variables" do
        id = ENV.fetch("SHOPIFY_CUSTOMER_ID")
        id = "gid://shopify/Customer/#{id}"

        result = client.execute(<<-GQL, :id => id)
          query findCustomer($id: ID!) {
            customer(id: $id) {
              id
            }
          }
        GQL

        expect(result.dig(:data, :customer, :id)).to eq id
      end

      it "raise a NotFoundError when the query target cannot be found" do
        expect {
          client.execute(<<-GQL, :id => "gid://shopify/Customer/1")
            query findCustomer($id: ID!) {
              customer(id: $id) {
                id
              }
            }
          GQL
          # 3.4 changes Hash#inspect output
        }.to raise_error(described_class::NotFoundError, %r|\ANo record found for customer with {"id"\s*=>\s*"gid://shopify/Customer/1"}|)
      end

      context "when :raise_if_not_found is false" do
        it "returns the response and does not raise a NotFoundError when the query target cannot be found" do
          result = nil

          expect {
            result = client.execute(<<-GQL, {:id => "gid://shopify/Customer/1"}, :raise_if_not_found => false)
              query findCustomer($id: ID!) {
                customer(id: $id) {
                  id
                }
              }
            GQL
          }.to_not raise_error

          expect(result).to be_a(Hash)
          expect(result.dig(:data, :customer)).to be_nil
        end
      end

      context "when :snake_case is false" do
        it "returns the query without snake_case symbol keys" do
          id = ENV.fetch("SHOPIFY_CUSTOMER_ID")
          id = "gid://shopify/Customer/#{id}"

          result = client(:snake_case => false).execute(<<-GQL, :id => id)
            query findCustomer($id: ID!) {
              customer(id: $id) {
                id
                firstName
              }
            }
          GQL

          customer = result.dig("data", "customer")
          expect(customer).to be_a(Hash)

          expect(customer["id"]).to eq id
          # Use this to ensure we're not camel_casing
          expect(customer).to include("firstName")
        end
      end
    end

    describe "mutations" do
      it "executes mutations" do
        id = ENV.fetch("SHOPIFY_CUSTOMER_ID")
        value = Time.now.to_i.to_s
        input = {
          :ownerId => "gid://shopify/Customer/#{id}",
          :namespace => "shopify_api-graphql-request",
          :key => "testsuite",
          :type => "single_line_text_field",
          :value => value
        }

        result = client.execute(<<-GQL, :metafields => [input])
          mutation metafieldsSet($metafields: [MetafieldsSetInput!]!) {
            metafieldsSet(metafields: $metafields) {
              metafields {
                key
                namespace
                value
              }
            }
          }
        GQL

        data = result.dig(:data, :metafields_set, :metafields, 0)
        expect(data).to eq(:key => "testsuite", :namespace => "shopify_api-graphql-request", :value => value)
      end

      it "raise a UserError when the response contains userErrors" do
        expect {
          client.execute(<<-GQL, :input => { :id => "gid://shopify/Customer/1", :first_name => "sshaw" })
            mutation($input: CustomerInput!) {
              customerUpdate(input: $input) {
                customer {
                  id
                }
                userErrors {
                  message
                  field
                }
              }
            }
          GQL
        }.to raise_error(described_class::UserError, "id: Customer does not exist") { |error|
          expect(error.errors).to eq ["field" => %w[id], "message" => "Customer does not exist"]
        }
      end

      context "when :raise_if_user_errors is false" do
        it "returns the response and does not raise a UserError when the response contains userErrors" do
          result = nil

          expect {
            result = client.execute(<<-GQL, {:input => { :id => "gid://shopify/Customer/1", :first_name => "sshaw" }}, :raise_if_user_errors => false)
              mutation($input: CustomerInput!) {
                customerUpdate(input: $input) {
                  customer {
                    id
                  }
                  userErrors {
                    message
                    field
                  }
                }
              }
            GQL
          }.to_not raise_error

          expect(result).to be_a(Hash)
          expect(result.dig(:data, :customer_update)).to eq(:customer=>nil, :user_errors => [:message => "Customer does not exist", :field => ["id"]])
        end
      end
    end
  end

  describe "#paginate" do
    def position_node_at(at)
      [:data, :product, :variants, :edges, at, :node]
    end

    before do
      @query = <<-GQL
        query product($id: ID! $after: String) {
          product(id: $id) {
            variants(first:1 sortKey: POSITION after: $after ) {
              pageInfo {
                hasNextPage
                endCursor
              }
              edges {
                node {
                  position
                }
              }
            }
          }
        }
      GQL

      @id = "gid://shopify/Product/%s" % ENV.fetch("SHOPIFY_PRODUCT_ID")
    end

    it "paginates without a block" do
      positions = []

      results = client.paginate(@query, :id => @id)
      results.each { |page| positions << page.dig(*position_node_at(0)).fetch(:position) }

      expect(positions.size).to be > 1, "test using a Shopify product with more than 1 variant"
      expect(positions).to eq positions.sort
    end

    it "paginates with a block" do
      positions = []

      client.paginate(@query, :id => @id) { |page| positions << page.dig(*position_node_at(0)).fetch(:position) }

      expect(positions.size).to be > 1, "test using a Shopify product with more than 1 variant"
      expect(positions).to eq positions.sort
    end

    it "raise a NotFoundError when the query target cannot be found" do
      expect {
        client.paginate(@query, :id => "gid://shopify/Product/1").first
        # 3.4 changes Hash#inspect output
      }.to raise_error(described_class::NotFoundError, %r|\ANo record found for product with {"id"\s*=>\s*"gid://shopify/Product/1"}|)
    end
  end

  describe "token refreshing via the :refresh option" do
    before do
      @oauth = ShopifyAPI::GraphQL::Request::OAuth::AccessToken.new("client-id", "client-secret", "test-shop")
      allow(@oauth).to receive(:refresh).and_return(
        "access_token" => "new-token",
        "expires_in" => 3600,
        "refresh_token" => "new-refresh-token",
        "refresh_token_expires_in" => 7776000
      )
      allow(ShopifyAPI::GraphQL::Request::OAuth::AccessToken).to receive(:new).and_return(@oauth)

      @gql = ShopifyAPI::GraphQL::Tiny.new("test-shop", "old-token")
      allow(@gql).to receive(:execute).and_return("data" => { "shop" => { "name" => "Test Shop" } })
      allow(ShopifyAPI::GraphQL::Tiny).to receive(:new).and_return(@gql)
    end

    def request(options = nil)
      described_class.new("test-shop", "old-token", options)
    end

    def refresh_options(synchronize = nil, overrides = nil)
      {
        :refresh => {
          :client_id => "client-id",
          :client_secret => "client-secret",
          :expires_at => Time.now.to_i - 60,
          :refresh_token => "refresh-token",
          :refresh_expires_at => Time.now.to_i + 7776000,
          :synchronize => synchronize || ->(refresh, shop) {
            refresh.call(
              :access_token => "db-token",
              :expires_at => Time.now.to_i - 60,
              :refresh_token => "db-refresh-token",
              :refresh_expires_at => Time.now.to_i + 7776000
            )
          }
        }.merge(overrides || {})
      }
    end

    def unauthorized_then_success
      calls = 0
      allow(@gql).to receive(:execute) do
        calls += 1
        raise ShopifyAPI::GraphQL::Tiny::HTTPError.new("Unauthorized", "401") if calls == 1

        { "data" => { "shop" => { "name" => "Test Shop" } } }
      end
    end

    it "raises ArgumentError when refresh options are missing" do
      expect {
        request(:refresh => { :client_id => "client-id" })
      }.to raise_error(ArgumentError, ":refresh requires client_secret, expires_at, refresh_token, refresh_expires_at, synchronize")
    end

    it "raises ArgumentError when :refresh is not a Hash" do
      expect {
        request(:refresh => true)
      }.to raise_error(ArgumentError, ":refresh must be a Hash")
    end

    it "raises ArgumentError when :expires_at is a relative offset instead of an epoch timestamp" do
      expect {
        request(refresh_options(nil, :expires_at => 3600))
      }.to raise_error(ArgumentError, %r|:expires_at must be a Time or modern Unix epoch timestamp in seconds, not a relative offset \(got 3600\)|)
    end

    it "raises ArgumentError when :refresh_expires_at is a relative offset instead of an epoch timestamp" do
      expect {
        request(refresh_options(nil, :refresh_expires_at => 7776000))
      }.to raise_error(ArgumentError, %r|:refresh_expires_at must be a Time or modern Unix epoch timestamp in seconds, not a relative offset \(got 7776000\)|)
    end

    it "raises ArgumentError when :expires_at is not a Time or Numeric" do
      expect {
        request(refresh_options(nil, :expires_at => "invalid"))
      }.to raise_error(ArgumentError, %r|:expires_at must be a Time or Integer Unix epoch timestamp \(got "invalid"\)|)
    end

    it "raises ArgumentError when state passed to refresh.call has a relative offset" do
      options = refresh_options(->(refresh, shop) {
        refresh.call(:access_token => "token", :expires_at => 3600)
      })
      expect {
        request(options).execute("{ shop { name } }")
      }.to raise_error(ArgumentError, %r|:expires_at must be a Time or modern Unix epoch timestamp in seconds, not a relative offset \(got 3600\)|)
    end

    it "refreshes an expired token before executing" do
      request(refresh_options).execute("{ shop { name } }")

      expect(@oauth).to have_received(:refresh).with("db-refresh-token")
      expect(ShopifyAPI::GraphQL::Tiny).to have_received(:new).with("test-shop", "new-token", anything)
    end

    it "accepts a Time instance for :expires_at" do
      request(refresh_options(nil, :expires_at => Time.now - 60)).execute("{ shop { name } }")

      expect(ShopifyAPI::GraphQL::Tiny).to have_received(:new).with("test-shop", "new-token", anything)
    end

    it "uses the persisted token when another process refreshed first" do
      options = refresh_options(->(refresh, shop) {
        refresh.call(
          :access_token => "fresh-db-token",
          :expires_at => Time.now.to_i + 3600,
          :refresh_token => "fresh-db-refresh-token",
          :refresh_expires_at => Time.now.to_i + 7776000
        )
      })

      request(options).execute("{ shop { name } }")

      expect(@oauth).to_not have_received(:refresh)
      expect(ShopifyAPI::GraphQL::Tiny).to have_received(:new).with("test-shop", "fresh-db-token", anything)
    end

    it "passes the shop to the synchronize proc" do
      shops = []
      options = refresh_options(->(refresh, shop) {
        shops << shop
        refresh.call(
          :access_token => "db-token",
          :expires_at => Time.now.to_i - 60,
          :refresh_token => "db-refresh-token",
          :refresh_expires_at => Time.now.to_i + 7776000
        )
      })

      request(options).execute("{ shop { name } }")

      expect(shops).to eq ["test-shop"]
    end

    it "refreshes when refresh proc is called without arguments" do
      options = refresh_options(->(refresh, shop) { refresh.call })
      request(options).execute("{ shop { name } }")

      expect(@oauth).to have_received(:refresh).with("refresh-token")
      expect(ShopifyAPI::GraphQL::Tiny).to have_received(:new).with("test-shop", "new-token", anything)
    end

    it "raises a RefreshNotCalledError when the synchronize proc does not call refresh" do
      options = refresh_options(->(refresh, shop) {
        # Does not call refresh
      })

      expect {
        request(options).execute("{ shop { name } }")
      }.to raise_error(described_class::RefreshNotCalledError, ":synchronize did not call refresh")
    end

    it "refreshes and retries once when the API returns 401" do
      unauthorized_then_success

      options = refresh_options(nil, :expires_at => Time.now.to_i + 3600, :refresh_token => "db-refresh-token")
      options[:refresh][:synchronize] = ->(refresh, shop) {
        refresh.call(
          :access_token => "old-token",
          :expires_at => Time.now.to_i + 3600,
          :refresh_token => "db-refresh-token",
          :refresh_expires_at => Time.now.to_i + 7776000
        )
      }

      result = request(options).execute("{ shop { name } }")

      expect(result).to eq(:data => { :shop => { :name => "Test Shop" } })
      expect(@gql).to have_received(:execute).twice
      expect(@oauth).to have_received(:refresh).once.with("db-refresh-token")
    end

    it "refreshes after 401 when refresh proc is called without arguments" do
      unauthorized_then_success

      options = refresh_options(->(refresh, shop) { refresh.call }, :expires_at => Time.now.to_i + 3600)
      result = request(options).execute("{ shop { name } }")

      expect(result).to eq(:data => { :shop => { :name => "Test Shop" } })
      expect(@oauth).to have_received(:refresh).once.with("refresh-token")
      expect(@gql).to have_received(:execute).twice
    end

    context "with a ClientAssertion as the :client_secret" do
      before do
        @assertion = ShopifyAPI::GraphQL::Request::OAuth::ClientAssertion.new("client-id", OpenSSL::PKey::RSA.generate(2048), "key-id")
        allow(@oauth).to receive(:client_credentials).and_return(
          "access_token" => "app-only-token",
          "expires_in" => 3599
        )
      end

      def assertion_options(synchronize = nil, overrides = nil)
        {
          :refresh => {
            :client_id => "client-id",
            :client_secret => @assertion,
            :expires_at => Time.now.to_i - 60,
            :synchronize => synchronize || ->(refresh, shop) { refresh.call }
          }.merge(overrides || {})
        }
      end

      it "does not require :refresh_token or :refresh_expires_at" do
        expect { request(assertion_options) }.to_not raise_error
      end

      it "still requires the other :refresh options" do
        expect {
          request(:refresh => { :client_secret => @assertion })
        }.to raise_error(ArgumentError, ":refresh requires client_id, expires_at, synchronize")
      end

      it "gets a new token with #client_credentials when the token is expired" do
        request(assertion_options).execute("{ shop { name } }")

        expect(@oauth).to have_received(:client_credentials).once
        expect(@oauth).to_not have_received(:refresh)
        expect(@gql).to have_received(:execute).once
      end

      it "yields the new token state to :synchronize without a refresh token" do
        state = nil
        synchronize = ->(refresh, shop) { state = refresh.call }

        request(assertion_options(synchronize)).execute("{ shop { name } }")

        expect(state).to include(:access_token => "app-only-token", :refresh_token => nil, :refresh_expires_at => nil)
        expect(state[:expires_at]).to be_within(5).of(Time.now.to_i + 3599)
      end

      it "does not get a new token when the token is not expired" do
        request(assertion_options(nil, :expires_at => Time.now.to_i + 3600)).execute("{ shop { name } }")

        expect(@oauth).to_not have_received(:client_credentials)
      end

      it "uses the persisted token when another process refreshed first" do
        synchronize = ->(refresh, shop) do
          refresh.call(:access_token => "db-token", :expires_at => Time.now.to_i + 3600)
        end

        request(assertion_options(synchronize)).execute("{ shop { name } }")

        expect(@oauth).to_not have_received(:client_credentials)
      end

      it "gets a new token and retries once when the API returns 401" do
        unauthorized_then_success

        options = assertion_options(nil, :expires_at => Time.now.to_i + 3600)
        result = request(options).execute("{ shop { name } }")

        expect(result).to eq(:data => { :shop => { :name => "Test Shop" } })
        expect(@oauth).to have_received(:client_credentials).once
        expect(@gql).to have_received(:execute).twice
      end
    end
  end
end
