# frozen_string_literal: true

module ShopifyAPI
  module GraphQL
    class Request
      ##
      # A Shopify shop's fully qualified +myshopify.com+ domain.
      #
      # Converts to a +String+ via +#to_s+ and +#to_str+.
      #
      class Shop
        SHOPIFY_DOMAIN = ".myshopify.com"

        ##
        # === Arguments
        #
        # [store (String|Shop)] Shop's handle, e.g. +my-shop+, or its domain, optionally with a scheme.
        #
        # === Errors
        #
        # ArgumentError if +store+ is blank.
        #
        def initialize(store)
          store = store.to_s.strip.sub(%r{\Ahttps?://}i, "")
          raise ArgumentError, "shop required" if store.empty?

          @domain = store.end_with?(SHOPIFY_DOMAIN) ? store : "#{store}#{SHOPIFY_DOMAIN}"
        end

        def to_s
          @domain.dup
        end

        alias to_str to_s
      end
    end
  end
end
