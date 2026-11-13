# frozen_string_literal: true
require "jwt"
require "openssl"
require "securerandom"

require "shopify_api/graphql/request/oauth"
require "shopify_api/graphql/request/shop"

module ShopifyAPI
  module GraphQL
    class Request
      module OAuth
        ##
        # Builds signed, single-use JWT client assertions for Shopify application-only access tokens.
        #
        class ClientAssertion
          MAX_STRING_SIZE = 255
          LIFETIME = 60
          RSA_KEY_SIZES = (2048..8192).freeze
          EC_CURVE = "prime256v1"

          ##
          # === Arguments
          #
          # [client_id (String)] App's client ID
          # [private_key (OpenSSL::PKey::RSA|OpenSSL::PKey::EC|String)] Private key or PEM encoded private key.
          #                                                              RSA (2048-8192 bits) or EC (prime256v1).
          # [key_id (String)] ID of the corresponding public key registered with Shopify
          #
          # === Errors
          #
          # ArgumentError if an argument is invalid or the key is not a supported private key.
          #
          def initialize(client_id, private_key, key_id)
            raise ArgumentError, "client_id required" if client_id.to_s.strip.empty?
            raise ArgumentError, "client_id too long" if client_id.to_s.size > MAX_STRING_SIZE
            raise ArgumentError, "key_id required" if key_id.to_s.strip.empty?
            raise ArgumentError, "key_id too long" if key_id.to_s.size > MAX_STRING_SIZE
            raise ArgumentError, "key_id must not have leading or trailing whitespace" if key_id.to_s != key_id.to_s.strip

            @client_id = client_id
            @key_id = key_id
            @private_key = read_key(private_key)
            @alg = algorithm(@private_key)
          end

          ##
          # Build and sign a JWT for the given shop.
          #
          # === Arguments
          #
          # [shop (String|Shop)] Shopify domain the assertion is for
          #
          # === Returns
          #
          # [String] The JWT
          #
          # === Errors
          #
          # ArgumentError if no +shop+ is provided.
          #
          def to_jwt(shop)
            now = Time.now.to_i
            payload = {
              :iss => @client_id,
              :sub => @client_id,
              :aud => sprintf(TOKEN_ENDPOINT, Shop.new(shop)),
              :iat => now,
              :exp => now + LIFETIME,
              :jti => SecureRandom.uuid
            }

            JWT.encode(payload, @private_key, @alg, :kid => @key_id)
          end

          private

          def read_key(key)
            key = OpenSSL::PKey.read(key) if key.is_a?(String)
            raise ArgumentError, "private_key required" unless key.is_a?(OpenSSL::PKey::PKey)
            raise ArgumentError, "private_key must be a private key" unless private_key?(key)

            key
          rescue OpenSSL::PKey::PKeyError => e
            raise ArgumentError, "invalid private_key: #{e.message}"
          end

          def private_key?(key)
            key.respond_to?(:private?) ? key.private? : key.private_key?
          end

          def algorithm(key)
            if key.is_a?(OpenSSL::PKey::RSA)
              raise ArgumentError, "RSA private_key must be 2048 to 8192 bits" unless RSA_KEY_SIZES.include?(key.n.num_bits)

              "RS256"
            elsif key.is_a?(OpenSSL::PKey::EC)
              raise ArgumentError, "EC private_key must use the #{EC_CURVE} curve" unless key.group.curve_name == EC_CURVE

              "ES256"
            else
              raise ArgumentError, "unsupported private_key type: #{key.class}"
            end
          end
        end
      end
    end
  end
end
