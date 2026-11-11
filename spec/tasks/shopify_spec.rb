# frozen_string_literal: true

require "rake"

RSpec.describe "shopify_api:graphql:request:migrate_access_tokens" do
  before(:all) do
    Rake.application.rake_require("tasks/shopify", [File.expand_path("../../lib", __dir__)])
  end

  around do |example|
    original_env = ENV.to_h
    %w[SHOPIFY_API_KEY SHOPIFY_API_SECRET SHOP FILE TOKEN HANDLER].each { |key| ENV.delete(key) }

    example.run
  ensure
    ENV.replace(original_env)
  end

  before do
    @task = Rake::Task["shopify_api:graphql:request:migrate_access_tokens"]
    @task.reenable
  end

  it "aborts if SHOPIFY_API_KEY is missing" do
    ENV["SHOPIFY_API_SECRET"] = "secret"
    expect { @task.invoke }.to raise_error(SystemExit)
  end

  it "aborts if SHOPIFY_API_SECRET is missing" do
    ENV["SHOPIFY_API_KEY"] = "id"
    expect { @task.invoke }.to raise_error(SystemExit)
  end

  it "aborts with the migrator's error message" do
    ENV["SHOPIFY_API_KEY"] = "id"
    ENV["SHOPIFY_API_SECRET"] = "secret"

    expect { @task.invoke }.to raise_error(SystemExit).and output(/shop or file required/).to_stderr
  end

  it "passes env vars to the migrator" do
    ENV["SHOPIFY_API_KEY"] = "id"
    ENV["SHOPIFY_API_SECRET"] = "secret"
    ENV["SHOP"] = "my-shop"
    ENV["TOKEN"] = "legacy"
    ENV["FILE"] = "f.csv"
    ENV["HANDLER"] = "h.rb"

    migrator = ShopifyAPI::GraphQL::Request::OAuth::AccessTokenMigrator.new("id", "secret", :shop => "my-shop", :token => "legacy")
    expect(ShopifyAPI::GraphQL::Request::OAuth::AccessTokenMigrator).to receive(:new)
      .with("id", "secret", :shop => "my-shop", :token => "legacy", :file => "f.csv", :handler => "h.rb")
      .and_return(migrator)
    expect(migrator).to receive(:run).and_return([])

    expect { @task.invoke }.to output.to_stdout
  end

  context "with results" do
    before do
      ENV["SHOPIFY_API_KEY"] = "id"
      ENV["SHOPIFY_API_SECRET"] = "secret"
      ENV["SHOP"] = "my-shop"
      ENV["TOKEN"] = "legacy"

      @migrator = ShopifyAPI::GraphQL::Request::OAuth::AccessTokenMigrator.new("id", "secret", :shop => "my-shop", :token => "legacy")
      allow(ShopifyAPI::GraphQL::Request::OAuth::AccessTokenMigrator).to receive(:new).and_return(@migrator)
    end

    it "prints a summary and exits non-zero when any shop failed" do
      allow(@migrator).to receive(:run).and_return([
        { :shop => "a.myshopify.com", :result => {}, :error => nil },
        { :shop => "b.myshopify.com", :result => nil, :error => "RuntimeError: boom" }
      ])

      status = nil
      expect do
        begin
          @task.invoke
        rescue SystemExit => e
          status = e.status
        end
      end.to output("Succeeded (1):\n  a.myshopify.com\nFailed (1):\n  b.myshopify.com: RuntimeError: boom\n").to_stdout

      expect(status).to eq(1)
    end

    it "does not exit when all shops succeeded" do
      allow(@migrator).to receive(:run).and_return([
        { :shop => "a.myshopify.com", :result => {}, :error => nil }
      ])

      expect { @task.invoke }.to output(/Failed \(0\)/).to_stdout
    end
  end
end
