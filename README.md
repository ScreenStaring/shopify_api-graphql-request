# ShopifyAPI::GraphQL::Request

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
