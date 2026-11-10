require "bundler/setup"
require "json"
require "vcr"

require "shopify_api/graphql/request"
require "dotenv/load" unless ENV["CI"]

VCR.configure do |config|
  config.cassette_library_dir = "spec/cassettes"
  config.hook_into :webmock
  config.configure_rspec_metadata!
  config.allow_http_connections_when_no_cassette = true

  %w[SHOPIFY_DOMAIN SHOPIFY_TOKEN SHOPIFY_CLIENT_API_KEY SHOPIFY_CLIENT_API_SECRET SHOPIFY_REFRESH_TOKEN].each do |var|
    config.filter_sensitive_data("<#{var}>") { ENV[var] }
  end

  # Dynamically scrub runtime tokens (such as newly issued access and refresh tokens
  # returned by Shopify OAuth responses and sent in subsequent request headers/bodies).
  # Unlike static credentials in ENV, these values are generated at runtime and cannot
  # be known before recording.
  config.before_record do |interaction|
    [interaction.response.body, interaction.request.body].each do |body|
      body.to_s.scan(/(?:shpca|shpat|shppa)_[a-zA-Z0-9]+/i) do |token|
        interaction.filter!(token, "<SHOPIFY_ACCESS_TOKEN>")
      end

      body.to_s.scan(/shprt_[a-zA-Z0-9]+/i) do |token|
        interaction.filter!(token, "<SHOPIFY_REFRESH_TOKEN>")
      end
    end

    interaction.request.headers.each_value do |values|
      Array(values).each do |value|
        value.to_s.scan(/(?:shpca|shpat|shppa)_[a-zA-Z0-9]+/i) do |token|
          interaction.filter!(token, "<SHOPIFY_ACCESS_TOKEN>")
        end
      end
    end
  end
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
