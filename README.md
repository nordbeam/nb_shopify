# NbShopify

A reusable Shopify integration library for Elixir applications. Built for modern Shopify apps using Managed Installation and embedded app patterns.

## Features

- **Session Token Verification**: Validate JWT session tokens from Shopify embedded apps
- **Token Exchange**: Automatic OAuth token exchange for Managed Installation flow
- **Webhook Verification**: HMAC-based webhook verification
- **API Clients**: GraphQL and REST API clients with built-in authentication
- **Phoenix Plugs**: Drop-in authentication and iframe header handling
- **Background Jobs**: Optional Oban worker for async webhook processing
- **Configurable**: Easy configuration with sensible defaults

## Installation

### Automatic Installation (Recommended)

The easiest way to install NbShopify is using the automated installer:

```bash
# Basic installation
mix igniter.install nb_shopify@github:nordbeam/nb_shopify

# Full installation with webhooks and database support
mix igniter.install nb_shopify@github:nordbeam/nb_shopify --with-webhooks --with-database

# With Shopify CLI support
mix igniter.install nb_shopify@github:nordbeam/nb_shopify --with-cli --with-webhooks --with-database

# Custom API version
mix igniter.install nb_shopify@github:nordbeam/nb_shopify --api-version "2025-10" --with-webhooks --with-database

# Or run the installer directly after adding the dependency
mix nb_shopify.install --with-webhooks --with-database --with-cli
```

The installer will:
- Add dependencies to `mix.exs`
- Create configuration in `config/runtime.exs`
- Set up router pipelines and routes
- Create Shop schema and context (if `--with-database`)
- Create webhook handler and controller (if `--with-webhooks`)
- Configure Oban for webhook processing (if `--with-webhooks`)

### Manual Installation

Add `nb_shopify` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:nb_shopify, "~> 0.1"},
    # Optional: for webhook processing
    {:oban, "~> 2.18"}
  ]
end
```

Then configure your Shopify API credentials in `config/runtime.exs`:

```elixir
# Production
if config_env() == :prod do
  config :nb_shopify,
    api_key: System.get_env("SHOPIFY_API_KEY") || raise("SHOPIFY_API_KEY not set"),
    api_secret: System.get_env("SHOPIFY_API_SECRET") || raise("SHOPIFY_API_SECRET not set"),
    api_version: "2026-01"
end

# Development
if config_env() == :dev do
  config :nb_shopify,
    api_key: System.get_env("SHOPIFY_API_KEY"),
    api_secret: System.get_env("SHOPIFY_API_SECRET"),
    api_version: "2026-01"
end
```

**SECURITY WARNING**: Never commit your Shopify API credentials! Always use environment variables.

## Quick Start

### 1. Set Up Authentication

Create a Shops context in your application:

```elixir
defmodule MyApp.Shops do
  import Ecto.Query
  alias MyApp.Repo
  alias MyApp.Shops.Shop

  def get_shop(id), do: Repo.get(Shop, id)

  def get_shop_by_domain(domain), do: Repo.get_by(Shop, shop_domain: domain)

  def upsert_shop(attrs) do
    case get_shop_by_domain(attrs.shop_domain) do
      nil -> %Shop{} |> Shop.changeset(attrs) |> Repo.insert()
      shop -> shop |> Shop.changeset(attrs) |> Repo.update()
    end
  end

  def post_install(shop, is_first_install) do
    if is_first_install do
      # Run first-time setup tasks
      IO.puts("Setting up shop: #{shop.shop_domain}")
    end
    :ok
  end
end
```

### 2. Add Plugs to Router

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  pipeline :shopify_app do
    plug NbShopifyWeb.Plugs.ShopifyFrameHeaders
    plug NbShopifyWeb.Plugs.ShopifySession,
      get_shop_by_id: &MyApp.Shops.get_shop/1,
      get_shop_by_domain: &MyApp.Shops.get_shop_by_domain/1,
      upsert_shop: &MyApp.Shops.upsert_shop/1,
      post_install: &MyApp.Shops.post_install/2
  end

  scope "/", MyAppWeb do
    pipe_through [:browser, :shopify_app]

    get "/", PageController, :index
  end
end
```

### 3. Access Shop in Controllers

After authentication, the shop is available in `conn.assigns.shop`:

```elixir
defmodule MyAppWeb.PageController do
  use MyAppWeb, :controller

  def index(conn, _params) do
    shop = conn.assigns.shop

    # Make API requests
    case NbShopify.graphql(shop, query, variables) do
      {:ok, response} ->
        # Handle response
      {:error, reason} ->
        # Handle error
    end

    render(conn, :index)
  end
end
```

## Usage Examples

### Session Token Verification

```elixir
case NbShopify.verify_session_token(token) do
  {:ok, %{"dest" => shop_url, "sub" => user_id}} ->
    # Token is valid
    IO.puts("Shop: #{shop_url}, User: #{user_id}")

  {:error, :token_expired} ->
    # Token has expired

  {:error, reason} ->
    # Other error
end
```

### Token Exchange (Managed Installation)

```elixir
case NbShopify.TokenExchange.exchange_token(shop_domain, session_token) do
  {:ok, %{access_token: token, scope: scope}} ->
    # Save token to database
    Shops.upsert_shop(%{
      shop_domain: shop_domain,
      access_token: token,
      scope: scope
    })

  {:error, reason} ->
    # Handle error
end
```

### GraphQL API Requests

```elixir
query = """
query getProduct($id: ID!) {
  product(id: $id) {
    id
    title
    description
    variants(first: 10) {
      edges {
        node {
          id
          title
          price
        }
      }
    }
  }
}
"""

variables = %{id: "gid://shopify/Product/123456789"}

case NbShopify.graphql(shop, query, variables) do
  {:ok, %{"data" => data}} ->
    product = data["product"]
    IO.puts("Product: #{product["title"]}")

  {:error, {:graphql_errors, errors}} ->
    IO.inspect(errors, label: "GraphQL Errors")

  {:error, reason} ->
    IO.inspect(reason, label: "Request Failed")
end
```

### REST API Requests

```elixir
# GET request
case NbShopify.rest(shop, :get, "products.json") do
  {:ok, %{"products" => products}} ->
    Enum.each(products, fn p -> IO.puts(p["title"]) end)

  {:error, reason} ->
    IO.inspect(reason)
end

# POST request
product_data = %{
  product: %{
    title: "New Product",
    body_html: "<p>Description</p>",
    vendor: "My Store"
  }
}

case NbShopify.rest(shop, :post, "products.json", product_data) do
  {:ok, %{"product" => product}} ->
    IO.puts("Created: #{product["id"]}")

  {:error, reason} ->
    IO.inspect(reason)
end
```

### Webhook Verification

In your webhook controller:

```elixir
defmodule MyAppWeb.WebhookController do
  use MyAppWeb, :controller

  # Important: Use Plug.Parsers with custom body reader
  plug :verify_webhook

  def create(conn, _params) do
    # Webhook is verified, process it
    topic = get_req_header(conn, "x-shopify-topic") |> List.first()
    shop_domain = get_req_header(conn, "x-shopify-shop-domain") |> List.first()

    # Option 1: Process immediately
    process_webhook(topic, shop_domain, conn.body_params)

    # Option 2: Enqueue for background processing (recommended)
    shop = Shops.get_shop_by_domain!(shop_domain)

    %{
      topic: topic,
      shop_id: shop.id,
      payload: conn.body_params
    }
    |> NbShopify.Workers.WebhookWorker.new()
    |> Oban.insert()

    json(conn, %{status: "ok"})
  end

  defp verify_webhook(conn, _opts) do
    hmac = get_req_header(conn, "x-shopify-hmac-sha256") |> List.first()

    # Read raw body (configure Plug.Parsers to store it)
    raw_body = conn.assigns.raw_body

    if NbShopify.verify_webhook_hmac(raw_body, hmac) do
      conn
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Invalid webhook signature"})
      |> halt()
    end
  end
end
```

### Reading Raw Body for Webhook Verification

In your endpoint, configure `Plug.Parsers` to preserve the raw body:

```elixir
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    body_reader: {MyAppWeb.CacheBodyReader, :read_body, []},
    json_decoder: Phoenix.json_library()

  # ... other plugs
end
```

Create the body reader:

```elixir
defmodule MyAppWeb.CacheBodyReader do
  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    conn = update_in(conn.assigns[:raw_body], &[body | &1 || []])
    {:ok, body, conn}
  end
end
```

### Background Webhook Processing (Oban)

1. Configure the webhook handler:

```elixir
config :nb_shopify, :webhook_handler,
  module: MyApp.ShopifyWebhookHandler,
  get_shop: &MyApp.Shops.get_shop!/1
```

2. Implement the handler:

```elixir
defmodule MyApp.ShopifyWebhookHandler do
  require Logger

  def handle_webhook(topic, shop, payload) do
    case topic do
      "products/create" ->
        handle_product_create(shop, payload)

      "products/update" ->
        handle_product_update(shop, payload)

      "products/delete" ->
        handle_product_delete(shop, payload)

      "app/uninstalled" ->
        handle_app_uninstalled(shop, payload)

      _ ->
        Logger.warning("Unhandled webhook topic: #{topic}")
        :ok
    end
  end

  defp handle_product_create(shop, payload) do
    Logger.info("Product created: #{payload["id"]} for shop #{shop.shop_domain}")
    # Your logic here
    :ok
  end

  defp handle_product_update(shop, payload) do
    Logger.info("Product updated: #{payload["id"]}")
    # Your logic here
    :ok
  end

  defp handle_product_delete(shop, payload) do
    Logger.info("Product deleted: #{payload["id"]}")
    # Your logic here
    :ok
  end

  defp handle_app_uninstalled(shop, _payload) do
    Logger.info("App uninstalled from #{shop.shop_domain}")
    # Clean up shop data, cancel subscriptions, etc.
    :ok
  end
end
```

3. Configure Oban in your application:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      MyApp.Repo,
      {Oban, repo: MyApp.Repo, queues: [webhooks: 10]},
      MyAppWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

## Database Schema Example

```elixir
defmodule MyApp.Shops.Shop do
  use Ecto.Schema
  import Ecto.Changeset

  schema "shops" do
    field :shop_domain, :string
    field :access_token, :string
    field :scope, :string

    timestamps()
  end

  def changeset(shop, attrs) do
    shop
    |> cast(attrs, [:shop_domain, :access_token, :scope])
    |> validate_required([:shop_domain, :access_token])
    |> unique_constraint(:shop_domain)
  end
end
```

Migration:

```elixir
defmodule MyApp.Repo.Migrations.CreateShops do
  use Ecto.Migration

  def change do
    create table(:shops) do
      add :shop_domain, :string, null: false
      add :access_token, :string, null: false
      add :scope, :string

      timestamps()
    end

    create unique_index(:shops, [:shop_domain])
  end
end
```

## Module Overview

- **`NbShopify`**: Core module with session token verification, webhook verification, and API clients
- **`NbShopify.TokenExchange`**: Handles OAuth token exchange for Managed Installation
- **`NbShopifyWeb.Plugs.ShopifySession`**: Phoenix plug for authentication and session management
- **`NbShopifyWeb.Plugs.ShopifyFrameHeaders`**: Sets headers for iframe embedding
- **`NbShopify.Workers.WebhookWorker`**: Oban worker for async webhook processing

## Testing

```elixir
# Test session token verification
test "verifies valid session token" do
  # Create test JWT
  token = create_test_token()
  assert {:ok, claims} = NbShopify.verify_session_token(token)
end

# Test webhook verification
test "verifies webhook HMAC" do
  body = Jason.encode!(%{id: 123})
  hmac = :crypto.mac(:hmac, :sha256, "secret", body) |> Base.encode64()
  assert NbShopify.verify_webhook_hmac(body, hmac)
end
```

## Migration Guide

If you're migrating from an app-specific implementation:

1. Install `nb_shopify` dependency
2. Update configuration to use `:nb_shopify` keys
3. Replace module references:
   - `YourApp.Shopify` → `NbShopify`
   - `YourApp.Shopify.TokenExchange` → `NbShopify.TokenExchange`
   - `YourAppWeb.Plugs.ShopifySession` → `NbShopifyWeb.Plugs.ShopifySession`
4. Update plug configuration to use callbacks
5. Configure webhook handler if using background processing

## Architecture Decisions

### Why Callbacks for ShopifySession?

The `ShopifySession` plug uses callbacks instead of directly calling your app's modules to:
- Avoid coupling to specific Ecto/database implementations
- Support any data store (Ecto, Mnesia, external APIs, etc.)
- Make testing easier with mock callbacks
- Allow flexibility in how shops are stored and retrieved

### Why Optional Oban?

The webhook worker uses Oban optionally to:
- Not force a specific background job system
- Allow synchronous webhook processing for simple apps
- Support apps that already use other job systems
- Keep the library lightweight

## Contributing

Contributions are welcome! Please open an issue or pull request.

## License

MIT License - See LICENSE file for details.

## Credits

Built by the Nb team. Extracted from production Shopify apps for reusability.
