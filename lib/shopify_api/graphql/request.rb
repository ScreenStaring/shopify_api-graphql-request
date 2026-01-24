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
      #
      # Additional options: those accepted by {ShopifyAPI::GraphQL::Tiny}[https://rdoc.info/gems/shopify_api-graphql-tiny]
      #
      def initialize(shop, token, options = nil)
        @options = (options || {}).dup

        [:snake_case, :raise_if_not_found, :raise_if_user_errors].each do |name|
          @options[name] = true unless @options.include?(name)
        end

        @gql = ShopifyAPI::GraphQL::Tiny.new(shop, token, @options)

        @gid = TinyGID.new("shopify")
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

        data = gql.execute(query, variables)

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
