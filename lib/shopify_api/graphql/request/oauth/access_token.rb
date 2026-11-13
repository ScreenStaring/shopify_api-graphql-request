# frozen_string_literal: true
require "json"
require "net/http"
require "uri"

require "shopify_api/graphql/request/oauth"
require "shopify_api/graphql/request/shop"
require "shopify_api/graphql/request/version"
require "shopify_api/graphql/request/oauth/client_assertion"

module ShopifyAPI
  module GraphQL
    class Request
      module OAuth
        ##
        # Shopify OAuth access token operations
        #
        class AccessToken
          InvalidTokenError = Class.new(Error)
          InvalidRefreshTokenError = Class.new(Error)

          TOKEN_EXCHANGE_GRANT_TYPE = "urn:ietf:params:oauth:grant-type:token-exchange"
          OFFLINE_TOKEN_TYPE = "urn:shopify:params:oauth:token-type:offline-access-token"
          REFRESH_TOKEN_GRANT_TYPE = "refresh_token"
          CLIENT_CREDENTIALS_GRANT_TYPE = "client_credentials"
          CLIENT_ASSERTION_TYPE = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

          USER_AGENT = "ShopifyAPI::GraphQL::Request v#{VERSION} (Ruby v#{RUBY_VERSION})"

          ##
          # === Arguments
          #
          # [client_id (String)] App's client ID
          # [client_secret (String|nil)] App's client secret. Optional if only using +#client_credentials+ with a +ClientAssertion+.
          # [options (Hash)] Client options. Optional.
          #
          # === Options
          #
          # [:open_timeout (Numeric)] Number of seconds to wait for the connection to open. Defaults to Net::HTTP's default.
          # [:read_timeout (Numeric)] Number of seconds to wait for a response. Defaults to Net::HTTP's default.
          # [:debug (Boolean|IO)] Output the HTTP request/response to +STDERR+ or to its value if it's an +IO+. Defaults to +false+.
          #
          # === Errors
          #
          # ArgumentError if no +client_id+ is provided.
          #
          def initialize(client_id, client_secret = nil, options = nil)
            raise ArgumentError, "client_id required" if client_id.to_s.strip.empty?

            if client_secret.is_a?(Hash) && options.nil?
              options = client_secret
              client_secret = nil
            end

            client_secret = client_secret.to_s.strip
            @client_id = client_id
            @client_secret = client_secret.empty? ? nil : client_secret

            options ||= {}

            @open_timeout = options[:open_timeout]
            @read_timeout = options[:read_timeout]

            if options[:debug]
              @debug = options[:debug].is_a?(IO) ? options[:debug] : $stderr
            end
          end

          ##
          # Migrate a legacy non-expiring offline access token to an expiring offline access token
          #
          # === Arguments
          #
          # [shop (String|Shop)] Shopify domain to make the request against
          # [non_expiring_token (String)] Existing non-expiring offline access token to migrate
          #
          # === Returns
          #
          # [Hash] The token response. Unmodified.
          #
          # === Errors
          #
          # ArgumentError, InvalidTokenError, Error
          #
          def migrate(shop, non_expiring_token)
            raise ArgumentError, "client_secret required" unless @client_secret
            raise ArgumentError, "token required" if non_expiring_token.to_s.strip.empty?

            request(
              shop,
              :client_id => @client_id,
              :client_secret => @client_secret,
              :grant_type => TOKEN_EXCHANGE_GRANT_TYPE,
              :subject_token => non_expiring_token,
              :subject_token_type => OFFLINE_TOKEN_TYPE,
              :requested_token_type => OFFLINE_TOKEN_TYPE,
              :expiring => 1
            )
          end

          ##
          # Refresh an expiring offline access token
          #
          # === Arguments
          #
          # [shop (String|Shop)] Shopify domain to make the request against
          # [refresh_token (String)] Refresh token to use
          #
          # === Returns
          #
          # [Hash] The token response. Unmodified.
          #
          # === Errors
          #
          # ArgumentError, InvalidRefreshTokenError, Error
          #
          def refresh(shop, refresh_token)
            raise ArgumentError, "client_secret required" unless @client_secret
            raise ArgumentError, "refresh token required" if refresh_token.to_s.strip.empty?

            request(
              shop,
              :client_id => @client_id,
              :client_secret => @client_secret,
              :grant_type => REFRESH_TOKEN_GRANT_TYPE,
              :refresh_token => refresh_token
            )
          end

          ##
          # Request an access token using the client credentials grant.
          # Uses the given +ClientAssertion+ if provided, otherwise the client secret.
          #
          # === Arguments
          #
          # [shop (String|Shop)] Shopify domain to make the request against
          # [assertion (ClientAssertion)] Optional signed client assertion for public apps
          #
          # === Returns
          #
          # [Hash] The token response. Unmodified.
          #
          # === Errors
          #
          # ArgumentError, Error
          #
          def client_credentials(shop, assertion = nil)
            domain = Shop.new(shop)
            params = {
              :client_id => @client_id,
              :grant_type => CLIENT_CREDENTIALS_GRANT_TYPE
            }

            if assertion
              raise ArgumentError, "assertion must be a ClientAssertion" unless assertion.is_a?(ClientAssertion)

              params[:client_assertion_type] = CLIENT_ASSERTION_TYPE
              params[:client_assertion] = assertion.to_jwt(domain)
            else
              raise ArgumentError, "client_secret required" unless @client_secret

              params[:client_secret] = @client_secret
            end

            request(domain, params)
          end

          private

          def request(shop, params)
            domain = shop.is_a?(Shop) ? shop : Shop.new(shop)
            endpoint = URI(sprintf(TOKEN_ENDPOINT, domain))

            response = post(endpoint, params)
            body = parse_body(response)

            handle_error(domain, response, body) unless response.is_a?(Net::HTTPSuccess)

            body
          end

          def post(endpoint, params)
            http = Net::HTTP.new(endpoint.host, endpoint.port)
            http.use_ssl = true
            http.open_timeout = @open_timeout if @open_timeout
            http.read_timeout = @read_timeout if @read_timeout
            http.set_debug_output(@debug) if @debug

            post = Net::HTTP::Post.new(endpoint.path)
            post.body = URI.encode_www_form(params)
            post["Content-Type"] = "application/x-www-form-urlencoded"
            post["Accept"] = "application/json"
            post["User-Agent"] = USER_AGENT

            http.start { |connection| connection.request(post) }
          end

          def parse_body(response)
            return if response.body.nil? || response.body.empty?
            return response.body unless response["Content-Type"].to_s.include?("json")

            JSON.parse(response.body)
          rescue JSON::ParserError => e
            raise Error, "failed to parse JSON response: #{e.message}"
          end

          def handle_error(domain, response, body)
            error = body["error"] if body.is_a?(Hash)
            message = error_message(body)

            if response.code == "400" && (error == "invalid_subject_token" || error == "invalid_requested_token_type")
              raise InvalidTokenError, "failed to migrate access token for #{domain}: #{message}"
            # RFC 6749 §5.2 specifies HTTP 400 for invalid_grant, but Shopify returns HTTP 401
            # when a refresh token is inactive, expired, or already rotated. Check both to be safe.
            elsif (response.code == "400" || response.code == "401") && error == "invalid_grant"
              raise InvalidRefreshTokenError, "failed to refresh access token for #{domain}: #{message}"
            else
              raise Error, "failed to request access token for #{domain}: #{message} (HTTP #{response.code})"
            end
          end

          def error_message(body)
            return body unless body.is_a?(Hash)

            body["error_description"] || body["error"] || body.to_s
          end
        end
      end
    end
  end
end
