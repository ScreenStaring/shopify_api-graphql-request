# frozen_string_literal: true

require "json"
require "jwt"
require "openssl"

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

      desc "Export a public key as a JWK. Requires KEY (PEM file), KID, and ALG (RS256 or ES256)."
      task :jwk_export do
        path = ENV["KEY"].to_s.strip
        kid = ENV["KID"].to_s.strip
        alg = ENV["ALG"].to_s.strip

        abort "KEY required" if path.empty?
        abort "KID required" if kid.empty?
        abort "ALG required" if alg.empty?

        key_types = { "RS256" => OpenSSL::PKey::RSA, "ES256" => OpenSSL::PKey::EC }
        abort "ALG must be one of: #{key_types.keys.join(", ")}" unless key_types.include?(alg)

        abort "KEY file not found: #{path}" unless File.file?(path)

        begin
          key = OpenSSL::PKey.read(File.read(path))
        rescue OpenSSL::PKey::PKeyError => e
          abort "invalid key: #{e.message}"
        end

        abort "key must be an #{key_types[alg].name.split("::").last} key for #{alg}" unless key.is_a?(key_types[alg])

        # Only the public parameters are exported
        puts JSON.pretty_generate(JWT::JWK.new(key, :kid => kid, :alg => alg, :use => "sig").export)
      end
    end
  end
end
