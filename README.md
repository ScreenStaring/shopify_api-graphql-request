# ShopifyAPI::GraphQL::Request

[![CI](https://github.com/ScreenStaring/shopify_api-graphql-request/actions/workflows/main.yml/badge.svg)](https://github.com/ScreenStaring/shopify_api-graphql-request/actions/workflows/main.yml)

Small class to simplify the writing and handling of GraphQL queries and mutations for the Shopify Admin API.
Comes with built-in retry, pagination, error handling, and more!

## Usage

Queries:

```rb
require "shopify_api/graphql/request"

request = ShopifyAPI::GraphQL::Request.new("a-shop", token)

begin
  product = request.execute(query, :id => "gid://shopify/Product/123").dig(:data, :product)
  p product[:title]
  p product[:description_html]
rescue ShopifyAPI::GraphQL::Request::NotFoundError => e
  p e
end
```

And mutations:

```rb
begin
  product = request.execute(mutation, :id => "gid://shopify/Product/123", :title => "Foo Hoo!").dig(:data, :product)
rescue ShopifyAPI::GraphQL::Request::UserError => e
  p e
end
```

If your application contains a lot of query and/or mutations it's recommended to organize them by
subclassing `ShopifyAPI::GraphQL::Request`:

```rb
class ShopifyProduct < ShopifyAPI::GraphQL::Request
  # Define your queries/mutations
  FIND =<<-GQL
    query($id: ID!) {
      product(id: $id) {
        id
        title
        descriptionHtml
      }
    }
  GQL

  UPDATE =<<-GQL
    mutation($product: ProductUpdateInput!) {
      productUpdate(product: $product) {
        product {
          id
          title
          descriptionHtml
        }
        userErrors {
          field
          message
        }
      }
    }
  GQL

  LIST <<-GQL
    query($after: String) {
      products(first: 25 after: $after) {
        pageInfo {
          hasNextPage
          endCursor
        }
        edges {
          node {
            id
            title
            descriptionHtml
          }
        }
      }
    }
  GQL

  def find(id)
    execute(FIND, :id => gid::Product(id)).dig(:data, :product)
  end

  def update(id, changes)
    execute(UPDATE, :product => changes.merge(:id => gid::Product(id))).dig(:data, :product_update, :product)
  end

  def list
    paginate(LIST) { |page| yield page.dig(:data, :products, :edges) }
  end
end
```

Then use it:

```rb
shopify = ShopifyProduct.new("a-shop", token)

begin
  product = shopify.find(123)
  p product[:id]
  p product[:description_html]
rescue ShopifyAPI::GraphQL::Request::NotFoundError => e
  warn "Product not found: #{e}"
end

begin
  product = shopify.update(123, :description_html => "Something amaaaazing!")
  p product[:id]
  p product[:description_html]
rescue ShopifyAPI::GraphQL::Request::UserError => e
  warn "User errors:"
  e.errors { |err| warn err["field"] }
end

begin
  shopify.list(123) do |node|
    product = node[:node]
    p product[:id]
    p product[:description_html]
  end
rescue ShopifyAPI::GraphQL::Request::NotFoundError => e
  warn "Request failed: #{e}"
end
```

Subclasses have access to the following methods:

- `#execute` - Execute a query or mutation with the provided arguments
- `#paginate` - Execute a query with pagination; without a block a lazy enumerator (`Enumerator::Lazy`) is returned
- `#gid` - Used for Global ID manipulation (an instance of [`TinyGID`](https://github.com/sshaw/tiny_gid/))
- `#gql` - The underlying GraphQL client (an instance of [`ShopifyAPI::GraphQL::Tiny`](https://github.com/ScreenStaring/shopify_api-graphql-tiny/))

`#execute` and `#paginate` also:

- Automatically retry failed or rate-limited requests
- Accept `snake_case` `Symbol` keys
- Return a `Hash` with `snake_case` `Symbol` keys
- Raise a `UserError` when a mutation's response contains `userErrors`
- Raise a `NotFoundError` when a query's result cannot be found

Both of these are small wrappers around the equivalent methods on `ShopifyAPI::GraphQL::Tiny`.
For more information see [its documentation on retries](https://github.com/ScreenStaring/shopify_api-graphql-tiny#automatically-retrying-failed-requests).

With the exception of retry, most defaults can be disabled per instance or per execution:

```rb
class ShopifyProduct < ShopifyAPI::GraphQL::Request
  def initialize(shop, token)
    super(shop, token, :raise_if_not_found => false, :raise_if_user_errors => false, :snake_case => false)
  end

  def find(gid)
    execute(QUERY, :raise_if_not_found => true)
  end
end
```

Disabling retry must be done per instance.

### Setting the GraphQL API Version

Pass the desired version to `Request`'s constructor:

```rb
class ShopifyProduct < ShopifyAPI::GraphQL::Request
  def initialize(shop, token)
    super(shop, token, :version => "2026-01")
  end
end
```

### Auto-Refreshing Expiring Access Tokens

`ShopifyAPI::GraphQL::Request` can automatically refresh Shopify's expiring offline access tokens before making a request, and automatically retry once on `401 Unauthorized` responses.

To enable auto-refresh, pass the `:refresh` option:

```rb
request = ShopifyAPI::GraphQL::Request.new(shop, token, :refresh => {
  :client_id => SHOPIFY_CLIENT_ID,
  :client_secret => SHOPIFY_CLIENT_SECRET,
  :refresh_token => refresh_token,
  :expires_at => expires_at, # Absolute Time or Integer Unix epoch timestamp
  :refresh_expires_at => refresh_expires_at, # Absolute Time or Integer Unix epoch timestamp
  :synchronize => ->(refresh, shopify_domain) do
    shop = Shop.find_by!(:shopify_domain => shopify_domain)

    shop.with_lock do
      updates = refresh.call  # see Multi-Process Concurrency section
      now = Time.now.to_i

      shop.update!(
        :access_token => tokens["access_token"],
        :expires_at => now + tokens["expires_in"],
        :refresh_token => tokens["refresh_token"],
        :refresh_expires_at => now + tokens["refresh_token_expires_in"]
      )
    end
  end
})
```

#### The `:synchronize` Callback

Because refreshed tokens must be persisted for future requests, `:synchronize` is required. It is passed a `refresh` proc and the shop's Shopify domain:

* `refresh.call` returns a `Hash` with `:access_token`, `:expires_at`, `:refresh_token`, and `:refresh_expires_at`. Note that `:expires_at` and `:refresh_expires_at` are absolute Unix epoch timestamps (in seconds), not relative duration offsets like Shopify's `expires_in`.
* Calling `refresh.call` without arguments refreshes using the client's **current in-memory token state**. If you're using multiple processes see [Multi-Process Concurrency](#multi-process-concurrency)

#### Multi-Process Concurrency

In multi-process environments multiple processes may attempt to refresh an expired token simultaneously. To prevent duplicate refresh requests and token invalidation
pass the freshly read storage state to `refresh`:

```rb
:synchronize => ->(refresh, shop) do
  shop = Shop.find_by!(:shopify_domain => shopify_domain)
  shop.with_lock do
    # Pass the latest token state.
    # If another worker already refreshed it refresh.call returns the fresh state without hitting Shopify.
    new_state = refresh.call(
      :access_token => shop.access_token,
      :expires_at => shop.expires_at,
      :refresh_token => shop.refresh_token,
      :refresh_expires_at => shop.refresh_expires_at
    )

    # save new_state
  end
end
```

### Migrating Non-Expiring Access Tokens

To migrate a legacy non-expiring offline access token to an expiring offline access token, call `ShopifyAPI::GraphQL::Request::OAuth::AccessToken#migrate`:

```rb
client = ShopifyAPI::GraphQL::Request::OAuth::AccessToken.new(
  SHOPIFY_CLIENT_ID,
  SHOPIFY_CLIENT_SECRET,
  shop
)

tokens = client.migrate(non_expiring_token)
```

`#migrate` returns Shopify's token exchange response `Hash`:

```rb
{
  "access_token" => "shpca_...",
  "scope" => "read_products,write_products",
  "expires_in" => 3599,
  "refresh_token" => "shprt_...",
  "refresh_token_expires_in" => 7775999
}
```

You can then calculate absolute expiration timestamps and persist the tokens for use with [Auto-Refreshing Expiring Access Tokens](#auto-refreshing-expiring-access-tokens):

```rb
now = Time.now.to_i

store.update!(
  :access_token => tokens["access_token"],
  :expires_at => now + tokens["expires_in"],
  :refresh_token => tokens["refresh_token"],
  :refresh_expires_at => now + tokens["refresh_token_expires_in"]
)
```

If the token is invalid or cannot be migrated, a `ShopifyAPI::GraphQL::Request::OAuth::AccessToken::InvalidTokenError` will be raised.

#### Rake Task

You can also migrate tokens using the provided rake task:

```sh
# Migrate a single shop:
bundle exec rake shopify_api:graphql:request:migrate_access_tokens SHOPIFY_API_KEY=X SHOPIFY_API_SECRET=Y SHOP=my-shop TOKEN=shpat_...

# Migrate from a CSV file (with "shop" and "token" columns). HANDLER is required, see below:
bundle exec rake shopify_api:graphql:request:migrate_access_tokens SHOPIFY_API_KEY=X SHOPIFY_API_SECRET=Y FILE=tokens.csv HANDLER=update_token.rb
```

A single shop's tokens are always printed. `HANDLER=file.rb` is required with `FILE` (nothing is printed for CSV) and optional with `SHOP`. Use it to persist the new tokens. The file is `load`ed and must define `update_token(shop, tokens)`, which is called with the
shop and the return value of `#migrate`:

```rb
# update_token.rb
def update_token(shop, tokens)
  Shop.find_by!(:domain => shop).update!(:access_token => tokens["access_token"], ...)
end
```

```sh
bundle exec rake shopify_api:graphql:request:migrate_access_tokens SHOPIFY_API_KEY=X SHOPIFY_API_SECRET=Y FILE=tokens.csv HANDLER=update_token.rb
```

#### Recovering a Lost Response

If a migration request fails or the response is lost, you can safely repeat the `#migrate` call with the original non-expiring token within
7 days of the initial exchange. Shopify will return the same token pair.

### More Info

For more information checkout [the API docs](https://rdoc.info/gems/shopify_api-graphql-request)

## Why Use This Instead of Shopify's API Client?

- Easy-to-use
- Built-in retry
- Built-in pagination
- Improved exception handling
- You can use `:snake_case` hash keys
- Lightweight

Overall, Shopify's API client is bloated trash that will give you development headaches and long-term maintenance nightmares.

We used to use it, staring way back in 2015, but eventually had to pivot away from their Ruby libraries due to developer
frustration and high maintenance cost (and don't get us started on the ShopifyApp gem!@#).

For more information see: https://github.com/Shopify/shopify-api-ruby/issues/1181

## Testing

`cp env.template .env` and fill-in `.env` with the missing values. This requires a Shopify store.

## See Also

- [Shopify Dev Tools](https://github.com/ScreenStaring/shopify-dev-tools/) - Command-line program to assist with the development and/or maintenance of Shopify apps and stores
- [`ShopifyAPI::GraphQL::Tiny`](https://github.com/ScreenStaring/shopify_api-graphql-tiny/) - Lightweight, no-nonsense, Shopify GraphQL Admin API client with built-in pagination and retry
- [`TinyGID`](https://github.com/sshaw/tiny_gid/) - Build Global ID (`gid://`) URI strings from scalar values

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

---

Made by [ScreenStaring](https://screenstaring.com)
