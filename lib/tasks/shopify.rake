# frozen_string_literal: true

require "shopify_api/graphql/request"
require "shopify_api/graphql/request/oauth/access_token_migrator"

namespace :shopify do
  desc "Migrate legacy non-expiring Shopify offline access tokens to expiring offline access tokens"
  task :migrate_access_tokens do
    client_id = ENV["SHOPIFY_API_KEY"].to_s.strip
    client_secret = ENV["SHOPIFY_API_SECRET"].to_s.strip

    abort "SHOPIFY_API_KEY required" if client_id.empty?
    abort "SHOPIFY_API_SECRET required" if client_secret.empty?

    begin
      ShopifyAPI::GraphQL::Request::OAuth::AccessTokenMigrator.new(
        client_id,
        client_secret,
        :shop => ENV["SHOP"],
        :token => ENV["TOKEN"],
        :file => ENV["FILE"],
        :handler => ENV["HANDLER"]
      ).run
    rescue ArgumentError => e
      abort e.message
    end
  end
end
