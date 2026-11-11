# frozen_string_literal: true

require "csv"
require "pp"

require "shopify_api/graphql/request/oauth/access_token"

module ShopifyAPI
  module GraphQL
    class Request
      module OAuth
        ##
        # Migrates legacy non-expiring offline access tokens to expiring ones for
        # a single shop or for many shops listed in a CSV file.
        #
        # Backs the +shopify_api:graphql:request:migrate_access_tokens+ rake task.
        #
        class AccessTokenMigrator
          HANDLER_METHOD = :update_token

          ##
          # === Arguments
          #
          # [client_id (String)] Shopify app client ID
          # [client_secret (String)] Shopify app client secret
          # [options (Hash)]
          #
          # === Options
          #
          # [:shop (String)] Shop to migrate.
          # [:token (String)] Non-expiring token for +:shop+
          # [:file (String)] CSV file with +shop+ and +token+ columns. Ignored if +:shop+ is given. Requires +:handler+.
          # [:handler (String)] Ruby file to +load+. It must define +update_token(shop, tokens)+, which is called
          #                     with the shop and the return value of AccessToken#migrate.
          # [:out (IO)] Where to write results. Defaults to +$stdout+.
          #
          # === Errors
          #
          # ArgumentError
          #
          def initialize(client_id, client_secret, options = {})
            @client_id = client_id
            @client_secret = client_secret
            @shop = nil_if_blank(options[:shop])
            @token = nil_if_blank(options[:token])
            @file = nil_if_blank(options[:file])
            @handler = nil_if_blank(options[:handler])
            @out = options[:out] || $stdout

            raise ArgumentError, "client_id required" if nil_if_blank(client_id).nil?
            raise ArgumentError, "client_secret required" if nil_if_blank(client_secret).nil?
            raise ArgumentError, "shop or file required" unless @shop || @file
            raise ArgumentError, "handler required when using file" if !@shop && !@handler
          end

          ##
          # Perform the migration(s).
          #
          # === Returns
          #
          # [Array<Hash>] One status per shop, in input order:
          #               +{ :shop => String, :result => Hash, :error => nil }+ or
          #               +{ :shop => String, :result => nil, :error => String }+.
          #               Per-shop errors (+StandardError+, including those raised by the handler) are
          #               rescued so one failure does not stop the rest.
          #
          # === Errors
          #
          # ArgumentError for invalid input (before any shop is processed)
          #
          def run
            pairs = @shop ? [single_shop_and_token] : rows
            load_handler if @handler

            pairs.map { |shop, token| migrate(shop, token) }
          end

          private

          def nil_if_blank(value)
            value unless value.to_s.strip.empty?
          end

          def load_handler
            raise ArgumentError, "Handler not found: #{@handler}" unless File.file?(@handler)

            load File.expand_path(@handler)
            return if respond_to?(HANDLER_METHOD, true)

            raise ArgumentError, "Handler must define #{HANDLER_METHOD}: #{@handler}"
          end

          def single_shop_and_token
            raise ArgumentError, "token required" unless @token

            [@shop, @token]
          end

          def rows
            raise ArgumentError, "File not found: #{@file}" unless File.file?(@file)

            table = CSV.read(@file, :headers => true, :skip_blanks => true, :converters => ->(value) { value&.strip }, :header_converters => ->(h) { h.to_s.strip.downcase })
            unless table.headers.include?("shop") && table.headers.include?("token")
              raise ArgumentError, "CSV must contain 'shop' and 'token' columns"
            end

            table.map { |row| [row["shop"], row["token"]] }.reject { |shop, token| shop.nil? && token.nil? }
          end

          def migrate(shop, token)
            client = AccessToken.new(@client_id, @client_secret, shop)
            result = client.migrate(token)

            @out.puts result.pretty_inspect if @shop

            call_handler(result, shop) if @handler

            { :shop => shop, :result => result, :error => nil }
          rescue StandardError => e
            { :shop => shop, :result => nil, :error => "#{e.class}: #{e.message}" }
          end

          def call_handler(result, shop)
            send(HANDLER_METHOD, shop, result)
          end
        end
      end
    end
  end
end
