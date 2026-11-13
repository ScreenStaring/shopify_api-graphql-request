# frozen_string_literal: true

require "strings/case"
require "tiny_gid"

require "shopify_api/graphql/tiny"

module ShopifyAPI
  module GraphQL
    #
    # Small class to simplify the writing and handling of GraphQL queries and mutations for the Shopify Admin API.
    # Comes with built-in retry, pagination, error handling, and more!
    #
    class Request
      Error = Class.new(StandardError)
      RefreshNotCalledError = Class.new(Error)

      # Smallest plausible Unix epoch timestamp (Sep 2001). Used to guard against callers
      # mistakenly passing relative duration offsets (e.g., 3600 or Shopify's `expires_in`)
      # instead of an absolute point in time.
      MIN_EPOCH_TIMESTAMP = 1_000_000_000

      class UserError < Error
        attr_reader :errors

        def initialize(errors)
          super error_message(errors)
          @errors = errors
        end

        private

        def error_message(errors)
          errors.map do |error|
            if error["field"]
              sprintf("%s: %s", error["field"].join("."), error["message"])
            else
              error["message"]
            end
          end.join("\n")
        end
      end

      class NotFoundError < Error
        def initialize(queries, variables)
          if queries.size > 1
            super "No records found for queries #{queries.join(", ")} with #{variables}"
          else
            super "No record found for #{queries[0]} with #{variables}"
          end
        end
      end

      ##
      #
      # Create a new GraphQL client to connect to +shop+
      #
      # === Arguments
      #
      # [shop (String)] Shopify domain to make requests against
      # [token (String)] Shopify API token
      # [options (Hash)] Client options. Optional.
      #
      # === Options
      #
      # [:raise_if_not_found (Boolean)] If +true+ raise a NotFoundError if the requested record is not found. Defaults to +true+.
      # [:raise_if_user_errors (Boolean)] If +true+ raise a UserError if the mutation resulted in user errors. Defaults to +true+.
      # [:snake_case (Boolean)] Convert response `Hash` keys to +snake_case+ symbols. Defaults to +true+.
      # [:refresh (Hash)] Auto-refresh expiring access tokens. Requires +:client_id+, +:client_secret+,
      #   +:expires_at+, +:refresh_token+, +:refresh_expires_at+, and +:synchronize+.
      #   +:expires_at+ and +:refresh_expires_at+ must be absolute timestamps (+Time+s or Integer Unix epoch timestamps in seconds),
      #   not relative duration offsets (e.g. Shopify's +expires_in+).
      #
      #   For application-only access tokens set +:client_secret+ to an OAuth::ClientAssertion.
      #   These tokens have no refresh token so +:refresh_token+ and +:refresh_expires_at+ are not used and
      #   are not required. A new token is obtained with OAuth::AccessToken#client_credentials.
      #
      #   +:synchronize+ is a Proc called with a refresh Proc and the shop. It should persist the new token
      #   state returned by the refresh Proc:
      #
      #     :synchronize => ->(refresh, shop) do
      #       store.update!(refresh.call)
      #     end
      #
      #   Calling +refresh.call+ without arguments uses the client's current in-memory token state.
      #   In multi-process environments, pass the freshly read token state from storage (e.g. +refresh.call(db_state)+)
      #   under a lock to prevent concurrent workers from performing duplicate refreshes.
      #
      # Additional options: those accepted by {ShopifyAPI::GraphQL::Tiny}[https://rdoc.info/gems/shopify_api-graphql-tiny]
      #
      def initialize(shop, token, options = nil)
        @options = (options || {}).dup

        [:snake_case, :raise_if_not_found, :raise_if_user_errors].each do |name|
          @options[name] = true unless @options.include?(name)
        end

        @shop = shop
        @gql = ShopifyAPI::GraphQL::Tiny.new(shop, token, @options)

        @gid = TinyGID.new("shopify")

        refresh = @options[:refresh]
        return unless refresh

        raise ArgumentError, ":refresh must be a Hash" unless refresh.is_a?(Hash)

        @client_assertion = refresh[:client_secret].is_a?(OAuth::ClientAssertion)

        required = [:client_id, :client_secret, :expires_at, :refresh_token, :refresh_expires_at, :synchronize]
        required -= [:refresh_token, :refresh_expires_at] if @client_assertion

        missing = required.reject { |name| refresh.include?(name) }
        raise ArgumentError, ":refresh requires #{missing.join(", ")}" if missing.any?

        validate_timestamp(:expires_at, refresh[:expires_at])
        validate_timestamp(:refresh_expires_at, refresh[:refresh_expires_at]) if refresh[:refresh_expires_at]

        @oauth = OAuth::AccessToken.new(refresh[:client_id], refresh[:client_secret], shop, @options)
        @synchronize = refresh[:synchronize]
        @token_state = {
          :access_token => token,
          :expires_at => refresh[:expires_at],
          :refresh_token => refresh[:refresh_token],
          :refresh_expires_at => refresh[:refresh_expires_at]
        }
      end

      ##
      #
      # Executes a query or mutation
      #
      # === Arguments
      #
      # [query (String)] Query or mutation to execute
      # [token (String)] Optional variables accepted by +query+
      # [options (Hash)] Optional
      #
      # === Options
      #
      #  These override the instance's defaults for a single query or mutation.
      #
      # [:raise_if_not_found (Boolean)] - raise a `ShopifyAPI::GraphQL::Request::NotFoundError` if query target is not found; defaults to +true+
      # [:raise_if_user_errors (Boolean)] - raise a `ShopifyAPI::GraphQL::Request::UserError` if the response contains them; defaults to +true+
      # [:snake_case (Boolean)] - Accept `:snake_case`-style hash keys and returned response hash keys to be snake_case; defaults to +true+
      #
      # === Returns
      #
      # The GraphQL response +Hash+
      #
      # === Errors
      #
      # * ArgumentError
      # * ShopifyAPI::GraphQL::Request::RefreshNotCalledError - if :synchronize did not invoke refresh
      # * ShopifyAPI::GraphQL::Request::UserError - the a mutation contains user errors
      # * ShopifyAPI::GraphQL::Request::NotFoundError - if the query cannot be find the given object
      # * ShopifyAPI::GraphQL::Tiny::ConnectionError
      # * ShopifyAPI::GraphQL::Tiny::HTTPError
      # * ShopifyAPI::GraphQL::Tiny::RateLimitError - if the retry attempts have been exceeded
      # * ShopifyAPI::GraphQL::Tiny::GraphQLError
      #
      def execute(query, variables = nil, options = nil)
        options = @options.merge(options || {})

        variables = camelize_keys(variables) if options[:snake_case]
        ensure_fresh_token

        begin
          data = gql.execute(query, variables)
        rescue ShopifyAPI::GraphQL::Tiny::HTTPError => error
          raise unless refreshable? && error.code == "401"

          refresh_after_401
          data = gql.execute(query, variables)
        end

        raise_if_not_found(data, variables) if options[:raise_if_not_found]
        raise_if_user_errors(data) if options[:raise_if_user_errors]

        data = snake_case_keys(data) if options[:snake_case]

        data
      end

      ##
      #
      # Executes a query using pagination.
      #
      # Using pagination requires you to include the
      # {PageInfo}[https://shopify.dev/api/admin-graphql/2026-01/objects/PageInfo] in your query.
      #
      # === Arguments
      #
      # Same as #execute but also accepts a block that will be called with each page.
      # If a block not given returns an instance of Enumerator::Lazy that will fetch the next
      # page on each iteration
      #
      # === Errors
      #
      # See #execute
      #
      def paginate(query, variables = nil, options = nil)
        options = @options.merge(options || {})

        variables = camelize_keys(variables) if options[:snake_case]
        ensure_fresh_token

        begin
          pager = gql.paginate
          # execute() returns a lazy enumerator so we're not loading everything now.
          pages = pager.execute(query, variables).map do |page|
            raise_if_not_found(page, variables) if options[:raise_if_not_found]
            raise_if_user_errors(page) if options[:raise_if_user_errors]

            page = snake_case_keys(page) if options[:snake_case]
            page
          end

          return pages unless block_given?

          pages.each { |page| yield page }
        rescue ShopifyAPI::GraphQL::Tiny::HTTPError => error
          raise unless refreshable? && error.code == "401"

          refresh_after_401
          retry
        end

        nil
      end

      protected

      attr_reader :gql, :gid

      def raise_if_not_found(data, variables)
        not_found = data["data"].select { |key, value| value.nil? }
        return unless not_found.any?

        raise NotFoundError.new(not_found.keys, variables)
      end

      def raise_if_user_errors(data)
        # FIXME: this does not account for multiple queries
        # Structure is { "data" => QUERY => { "userErrors" => [] } }
        data = data["data"].values[0]
        return unless data && data["userErrors"] && data["userErrors"].any?

        raise UserError, data["userErrors"]
      end

      def camelize_keys(object)
        transform_keys(object) { |key| Strings::Case.camelcase(key.to_s) }
      end

      def snake_case_keys(object)
        transform_keys(object) { |key| Strings::Case.snakecase(key).to_sym }
      end

      private

      def ensure_fresh_token
        return unless refreshable?
        return unless token_expired?(@token_state)

        synchronize(method(:refresh_tokens))
      end

      def refreshable?
        @oauth && @synchronize
      end

      def token_expired?(state)
        expires_at = state[:expires_at]
        expires_at && to_time(expires_at) <= Time.now
      end

      def to_time(value)
        return value.to_time if value.respond_to?(:to_time)

        validate_timestamp(:expires_at, value)
        Time.at(value)
      end

      # Ensures timestamp values are absolute points in time (Time instances or Unix epoch timestamps)
      # rather than relative offsets (e.g., passing `expires_in: 3600`), which would otherwise evaluate
      # to 1970 and cause continuous refresh loops.
      def validate_timestamp(name, value)
        return if value.respond_to?(:to_time)

        if value.is_a?(Numeric)
          return if value >= MIN_EPOCH_TIMESTAMP

          raise ArgumentError, ":#{name} must be a Time or modern Unix epoch timestamp in seconds, not a relative offset (got #{value})"
        end

        raise ArgumentError, ":#{name} must be a Time or Integer Unix epoch timestamp (got #{value.inspect})"
      end

      def refresh_tokens(state = @token_state)
        state ||= @token_state
        if token_expired?(state)
          @token_state = normalize_tokens(request_tokens(state))
        else
          @token_state = state
        end
      end

      def refresh_stale_tokens(state = @token_state)
        state ||= @token_state
        if state.equal?(@token_state) || state[:access_token] == @token_state[:access_token]
          @token_state = normalize_tokens(request_tokens(state))
        else
          @token_state = state
        end
      end

      # Application-only access tokens have no refresh token, get a new one with the client assertion
      def request_tokens(state)
        @client_assertion ? @oauth.client_credentials : @oauth.refresh(state[:refresh_token])
      end

      def refresh_after_401
        synchronize(method(:refresh_stale_tokens))
      end

      def synchronize(refresh)
        invoked = false
        callable = ->(*args, &block) do
          invoked = true
          refresh.call(*args, &block)
        end

        result = @synchronize.call(callable, @shop)
        raise RefreshNotCalledError, ":synchronize did not call refresh" unless invoked

        @token_state = result if result.is_a?(Hash) && result.key?(:access_token)
        @gql = ShopifyAPI::GraphQL::Tiny.new(@shop, @token_state[:access_token], @options)
        @token_state
      end

      def normalize_tokens(tokens)
        now = Time.now.to_i

        {
          :access_token => tokens["access_token"],
          :expires_at => now + tokens["expires_in"],
          :refresh_token => tokens["refresh_token"],
          :refresh_expires_at => tokens["refresh_token_expires_in"] ? now + tokens["refresh_token_expires_in"] : nil
        }
      end

      def transform_keys(object, &transformer)
        case object
        when Hash
          object.each_with_object({}) do |(key, value), result|
            result[transformer[key]] = transform_keys(value, &transformer)
          end
        when Array
          object.map { |value| transform_keys(value, &transformer) }
        else
          object
        end
      end
    end
  end
end

require "shopify_api/graphql/request/shop"
require "shopify_api/graphql/request/oauth/client_assertion"
require "shopify_api/graphql/request/oauth/access_token"
require "shopify_api/graphql/request/railtie" if defined?(Rails::Railtie)
