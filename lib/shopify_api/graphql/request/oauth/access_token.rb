# frozen_string_literal: true
require "json"
require "net/http"
require "uri"

require "shopify_api/graphql/request/version"

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

          TOKEN_ENDPOINT = "https://%s/admin/oauth/access_token"

          USER_AGENT = "ShopifyAPI::GraphQL::Request v#{VERSION} (Ruby v#{RUBY_VERSION})"

          SHOPIFY_DOMAIN = ".myshopify.com"

          ##
          # === Arguments
          #
          # [client_id (String)] App's client ID
          # [client_secret (String)] App's client secret
          # [shop (String)] Shopify domain to make requests against
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
          # ArgumentError if no +client_id+, +client_secret+, or +shop+ is provided.
          #
          def initialize(client_id, client_secret, shop, options = nil)
            raise ArgumentError, "client_id required" if client_id.to_s.strip.empty?
            raise ArgumentError, "client_secret required" if client_secret.to_s.strip.empty?
            raise ArgumentError, "shop required" if shop.to_s.strip.empty?

            @client_id = client_id
            @client_secret = client_secret
            @domain = shopify_domain(shop)

            options ||= {}

            @open_timeout = options[:open_timeout]
            @read_timeout = options[:read_timeout]

            if options[:debug]
              @debug = options[:debug].is_a?(IO) ? options[:debug] : $stderr
            end

            @endpoint = URI(sprintf(TOKEN_ENDPOINT, @domain))
          end

          ##
          # Migrate a legacy non-expiring offline access token to an expiring offline access token
          #
          # === Arguments
          #
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
          def migrate(non_expiring_token)
            raise ArgumentError, "token required" if non_expiring_token.to_s.strip.empty?

            request(
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
          def refresh(refresh_token)
            raise ArgumentError, "refresh token required" if refresh_token.to_s.strip.empty?

            request(
              :client_id => @client_id,
              :client_secret => @client_secret,
              :grant_type => REFRESH_TOKEN_GRANT_TYPE,
              :refresh_token => refresh_token
            )
          end

          private

          def request(params)
            response = post(params)
            body = parse_body(response)

            handle_error(response, body) unless response.is_a?(Net::HTTPSuccess)

            body
          end

          def post(params)
            http = Net::HTTP.new(@endpoint.host, @endpoint.port)
            http.use_ssl = true
            http.open_timeout = @open_timeout if @open_timeout
            http.read_timeout = @read_timeout if @read_timeout
            http.set_debug_output(@debug) if @debug

            post = Net::HTTP::Post.new(@endpoint.path)
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

          def handle_error(response, body)
            error = body["error"] if body.is_a?(Hash)
            message = error_message(body)

            if response.code == "400" && (error == "invalid_subject_token" || error == "invalid_requested_token_type")
              raise InvalidTokenError, "failed to migrate access token for #{@domain}: #{message}"
            # RFC 6749 §5.2 specifies HTTP 400 for invalid_grant, but Shopify returns HTTP 401
            # when a refresh token is inactive, expired, or already rotated. Check both to be safe.
            elsif (response.code == "400" || response.code == "401") && error == "invalid_grant"
              raise InvalidRefreshTokenError, "failed to refresh access token for #{@domain}: #{message}"
            else
              raise Error, "failed to request access token for #{@domain}: #{message} (HTTP #{response.code})"
            end
          end

          def error_message(body)
            return body unless body.is_a?(Hash)

            body["error_description"] || body["error"] || body.to_s
          end

          def shopify_domain(host)
            domain = host.sub(%r{\Ahttps?://}i, "")
            domain << SHOPIFY_DOMAIN unless domain.end_with?(SHOPIFY_DOMAIN)
            domain
          end
        end
      end
    end
  end
end
