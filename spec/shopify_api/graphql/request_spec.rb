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
end
