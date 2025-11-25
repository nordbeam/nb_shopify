# NbShopify Usage Rules

## What It Does
NbShopify is a Shopify integration library for Elixir/Phoenix apps. It handles:
- Session token (JWT) verification for embedded apps
- Token exchange for Managed Installation (OAuth replacement)
- Webhook HMAC verification
- GraphQL and REST API clients
- Phoenix authentication plugs
- Background webhook processing with Oban

## Installation

### Add to mix.exs
```elixir
{:nb_shopify, "~> 0.1"}
{:oban, "~> 2.18"}  # Optional: for webhook processing
```

### Configure in config/runtime.exs
```elixir
config :nb_shopify,
  api_key: System.get_env("SHOPIFY_API_KEY"),
  api_secret: System.get_env("SHOPIFY_API_SECRET"),
  api_version: "2026-01"
```

## Core Functions

### Session Token Verification
```elixir
case NbShopify.verify_session_token(token) do
  {:ok, %{"dest" => shop_url, "sub" => user_id}} -> # Valid
  {:error, reason} -> # Invalid
end
```

### Token Exchange (Managed Installation)
```elixir
case NbShopify.TokenExchange.exchange_token(shop_domain, session_token) do
  {:ok, %{access_token: token, scope: scope}} -> # Save to DB
  {:error, reason} -> # Handle error
end
```

### GraphQL API Requests
```elixir
query = """
query($id: ID!) {
  product(id: $id) { id title }
}
"""
NbShopify.graphql(shop, query, %{id: "gid://shopify/Product/123"})
# Returns: {:ok, response} | {:error, reason}
```

### REST API Requests
```elixir
NbShopify.rest(shop, :get, "products.json")
NbShopify.rest(shop, :post, "products.json", %{product: %{title: "New"}})
# Returns: {:ok, response} | {:error, reason}
```

### Webhook Verification
```elixir
NbShopify.verify_webhook_hmac(raw_body, hmac_header)
# Returns: {:ok, :verified} | {:error, :invalid_hmac}
```

## Phoenix Integration

### Router Setup
```elixir
pipeline :shopify_app do
  plug NbShopifyWeb.Plugs.ShopifyFrameHeaders
  plug NbShopifyWeb.Plugs.ShopifySession,
    get_shop_by_id: &MyApp.Shops.get_shop/1,
    get_shop_by_domain: &MyApp.Shops.get_shop_by_domain/1,
    upsert_shop: &MyApp.Shops.upsert_shop/1,
    post_install: &MyApp.Shops.post_install/2  # Optional
end

scope "/", MyAppWeb do
  pipe_through [:browser, :shopify_app]
  get "/", PageController, :index
end
```

### Access Shop in Controllers
After authentication, shop is available at `conn.assigns.shop`:
```elixir
def index(conn, _params) do
  shop = conn.assigns.shop
  NbShopify.graphql(shop, query, variables)
end
```

## Webhook Processing

### Configure Webhook Handler
```elixir
# config/runtime.exs
config :nb_shopify, :webhook_handler,
  module: MyApp.ShopifyWebhookHandler,
  get_shop: &MyApp.Shops.get_shop!/1
```

### Implement Handler Module
```elixir
defmodule MyApp.ShopifyWebhookHandler do
  def handle_webhook(topic, shop, payload) do
    case topic do
      "products/create" -> handle_product_create(shop, payload)
      "app/uninstalled" -> handle_app_uninstalled(shop, payload)
      _ -> :ok
    end
  end
end
```

### Enqueue from Controller
```elixir
%{topic: topic, shop_id: shop.id, payload: params}
|> NbShopify.Workers.WebhookWorker.new()
|> Oban.insert()
```

## Key Requirements

- Shop must have `:shop_domain` and `:access_token` fields
- Use environment variables for API credentials (never commit secrets)
- Configure body reader in endpoint for webhook verification
- Set up Oban with `:webhooks` queue for background processing

## Module Reference

- `NbShopify` - Core verification and API functions
- `NbShopify.TokenExchange` - OAuth token exchange
- `NbShopifyWeb.Plugs.ShopifySession` - Authentication plug
- `NbShopifyWeb.Plugs.ShopifyFrameHeaders` - Iframe headers
- `NbShopify.Workers.WebhookWorker` - Async webhook processing
