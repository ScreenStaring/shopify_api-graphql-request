# frozen_string_literal: true

require "shopify_api/graphql/request"
require "shopify_api/graphql/request/oauth/access_token_migrator"

namespace :shopify_api do
  namespace :graphql do
    namespace :request do
      desc "Migrate legacy non-expiring Shopify offline access tokens to expiring offline access tokens"
      task :migrate_access_tokens do
        client_id = ENV["SHOPIFY_API_KEY"].to_s.strip
        client_secret = ENV["SHOPIFY_API_SECRET"].to_s.strip

        abort "SHOPIFY_API_KEY required" if client_id.empty?
        abort "SHOPIFY_API_SECRET required" if client_secret.empty?

        begin
          statuses = ShopifyAPI::GraphQL::Request::OAuth::AccessTokenMigrator.new(
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

        failed, succeeded = statuses.partition { |status| status[:error] }

        puts "Succeeded (#{succeeded.size}):"
        succeeded.each { |status| puts "  #{status[:shop]}" }

        puts "Failed (#{failed.size}):"
        failed.each { |status| puts "  #{status[:shop]}: #{status[:error]}" }

        exit 1 unless failed.empty?
      end
    end
  end
end
