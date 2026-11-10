# frozen_string_literal: true

require "stringio"
require "tempfile"

require "shopify_api/graphql/request/oauth/access_token_migrator"

RSpec.describe ShopifyAPI::GraphQL::Request::OAuth::AccessTokenMigrator do
  RESULT = { "access_token" => "shpca_123", "refresh_token" => "shprt_456" }.freeze

  def migrator(options = {})
    described_class.new("id", "secret", { :out => @out }.merge(options))
  end

  def tempfile(name, content)
    file = Tempfile.new([name, File.extname(name)])
    file.write(content)
    file.close
    file
  end

  def access_token(shop)
    ShopifyAPI::GraphQL::Request::OAuth::AccessToken.new("id", "secret", shop)
  end

  before do
    @out = StringIO.new
  end

  describe "validation" do
    it "requires client_id" do
      expect { described_class.new(" ", "secret", :shop => "s", :token => "t") }.to raise_error(ArgumentError, /client_id/)
    end

    it "requires client_secret" do
      expect { described_class.new("id", nil, :shop => "s", :token => "t") }.to raise_error(ArgumentError, /client_secret/)
    end

    it "requires shop or file" do
      expect { migrator }.to raise_error(ArgumentError, /shop or file/)
    end

    it "requires a token when given a shop" do
      expect { migrator(:shop => "s").run }.to raise_error(ArgumentError, /token required/)
    end

    it "requires handler when using file" do
      expect { migrator(:file => "/no/such.csv") }.to raise_error(ArgumentError, /handler required/)
    end

    it "requires file to exist" do
      expect { migrator(:file => "/no/such.csv", :handler => "h.rb").run }.to raise_error(ArgumentError, /File not found/)
    end

    it "requires shop and token CSV columns" do
      file = tempfile("bad.csv", "domain,key\nshop1,tok1\n")
      expect { migrator(:file => file.path, :handler => "h.rb").run }.to raise_error(ArgumentError, /'shop' and 'token'/)
    ensure
      file.unlink
    end

    it "requires handler to exist" do
      expect { migrator(:shop => "s", :token => "t", :handler => "/no/such.rb").run }.to raise_error(ArgumentError, /Handler not found/)
    end

    it "requires handler to define update_token" do
      file = tempfile("handler.rb", "# nothing\n")
      expect { migrator(:shop => "s", :token => "t", :handler => file.path).run }.to raise_error(ArgumentError, /must define update_token/)
    ensure
      file.unlink
    end
  end

  describe "single shop" do
    before do
      @client = access_token("my-shop")
      allow(ShopifyAPI::GraphQL::Request::OAuth::AccessToken).to receive(:new).with("id", "secret", "my-shop").and_return(@client)
    end

    it "migrates and prints the result" do
      expect(@client).to receive(:migrate).with("legacy").and_return(RESULT)

      expect(migrator(:shop => "my-shop", :token => "legacy").run).to eq([{ :shop => "my-shop", :result => RESULT }])
      expect(@out.string).to include("shpca_123")
    end

    it "prefers shop over file" do
      expect(@client).to receive(:migrate).with("legacy").and_return(RESULT)
      migrator(:shop => "my-shop", :token => "legacy", :file => "/no/such.csv").run
    end
  end

  describe "CSV file" do
    after do
      Object.send(:remove_method, :update_token) if Object.private_method_defined?(:update_token)
    end

    it "migrates each row, calls the handler, and does not print" do
      file = tempfile("shops.csv", "Shop, Token\nshop1,tok_a\n,\nshop2,tok_b\n")
      handler = tempfile("handler.rb", "def update_token(shop, result); ($migrated ||= []) << shop; end\n")
      client1 = access_token("shop1")
      client2 = access_token("shop2")

      allow(ShopifyAPI::GraphQL::Request::OAuth::AccessToken).to receive(:new).with("id", "secret", "shop1").and_return(client1)
      allow(ShopifyAPI::GraphQL::Request::OAuth::AccessToken).to receive(:new).with("id", "secret", "shop2").and_return(client2)
      expect(client1).to receive(:migrate).with("tok_a").and_return(RESULT)
      expect(client2).to receive(:migrate).with("tok_b").and_return(RESULT)

      expect(migrator(:file => file.path, :handler => handler.path).run.map { |r| r[:shop] }).to eq(%w[shop1 shop2])
      expect($migrated).to eq(%w[shop1 shop2])
      expect(@out.string).to eq("")
    ensure
      file.unlink
      handler.unlink
      $migrated = nil
    end
  end

  describe "handler" do
    after do
      Object.send(:remove_method, :update_token) if Object.private_method_defined?(:update_token)
    end

    it "loads the file and calls update_token with the shop and result" do
      client = access_token("my-shop")
      allow(ShopifyAPI::GraphQL::Request::OAuth::AccessToken).to receive(:new).and_return(client)
      allow(client).to receive(:migrate).and_return(RESULT)

      file = tempfile("handler.rb", "def update_token(shop, result); $migrated = [shop, result]; end\n")
      migrator(:shop => "my-shop", :token => "legacy", :handler => file.path).run

      expect($migrated).to eq(["my-shop", RESULT])
    ensure
      file.unlink
      $migrated = nil
    end
  end
end
