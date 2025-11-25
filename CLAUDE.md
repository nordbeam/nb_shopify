# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

NbShopify is a reusable Elixir library for building Shopify embedded apps. It provides authentication, webhook handling, and API clients for Phoenix applications. The library uses **Managed Installation** flow (token exchange) rather than traditional OAuth authorization code grant.

## Key Architecture Patterns

### 1. Callback-Based Design

The library avoids coupling to specific implementations by using callback functions:

- **ShopifySession plug** (`lib/nb_shopify_web/plugs/shopify_session.ex:70-80`) requires callbacks for shop persistence:
  - `get_shop_by_id`: Fetch shop from database by ID
  - `get_shop_by_domain`: Fetch shop by Shopify domain
  - `upsert_shop`: Create or update shop record
  - `post_install`: Optional callback for post-installation tasks

This allows the library to work with any data store (Ecto, Mnesia, external APIs) without hard dependencies.

### 2. Authentication Flow

The authentication flow follows this sequence (see `lib/nb_shopify_web/plugs/shopify_session.ex:82-146`):

1. Check for existing session (returning users)
2. If no session, extract session token (JWT) from `id_token` param or Authorization header
3. Verify session token using HMAC-SHA256 with API secret
4. Exchange session token for long-lived access token via Managed Installation
5. Save/update shop using provided callbacks
6. Assign shop to `conn.assigns.shop`

### 3. Conditional Compilation

The library uses conditional compilation for optional dependencies:

- **Oban webhook worker** (`lib/nb_shopify/workers/webhook_worker.ex:1`): Only compiled if Oban is available
- **Igniter installer** (`lib/mix/tasks/nb_shopify.install.ex:1`): Only available if Igniter is loaded

This keeps the library lightweight while supporting advanced features.

### 4. Module Organization

```
lib/
├── nb_shopify.ex                          # Core API: JWT verification, webhook HMAC, GraphQL/REST clients
├── nb_shopify/
│   ├── config_error.ex                    # Configuration error exception
│   ├── token_exchange.ex                  # Managed Installation token exchange
│   └── workers/
│       └── webhook_worker.ex              # Optional Oban worker for async webhook processing
├── nb_shopify_web/
│   └── plugs/
│       ├── shopify_session.ex             # Main authentication plug (handles token exchange)
│       └── shopify_frame_headers.ex       # Sets headers for iframe embedding
└── mix/tasks/
    └── nb_shopify.install.ex              # Igniter-based installer task
```

## Common Development Commands

### Testing
```bash
mix test                                    # Run test suite
```

### Code Quality
```bash
mix format                                  # Format code
mix credo --strict                          # Run static analysis
```

### Documentation
```bash
mix docs                                    # Generate documentation
```

### Installation (for apps using this library)
```bash
# Basic installation
mix igniter.install nb_shopify@github:nordbeam/nb_shopify

# Full installation with webhooks and database
mix igniter.install nb_shopify@github:nordbeam/nb_shopify --with-webhooks --with-database

# With Shopify CLI support
mix igniter.install nb_shopify@github:nordbeam/nb_shopify --with-cli --with-webhooks --with-database
```

## Important Implementation Details

### Session Token Verification

Session tokens are JWTs signed with the app's client secret (see `lib/nb_shopify.ex:130-144`):

1. Verify signature using HS256 with API secret
2. Validate `dest` field ends with `.myshopify.com`
3. Validate `exp` (expiration) is in the future
4. Validate `aud` (audience) matches API key

### Token Exchange

The token exchange process (`lib/nb_shopify/token_exchange.ex:52-82`) converts short-lived session tokens to long-lived access tokens:

- Uses OAuth 2.0 Token Exchange (RFC 8693)
- Grant type: `urn:ietf:params:oauth:grant-type:token-exchange`
- Subject token type: `urn:ietf:params:oauth:token-type:id_token`
- Requested token type: `urn:shopify:params:oauth:token-type:offline-access-token`

This happens on every visit with a session token to handle reinstalls, scope changes, and token refreshes.

### Webhook HMAC Verification

Webhooks use HMAC-SHA256 verification (`lib/nb_shopify.ex:101-107`):

1. Compute HMAC of raw request body using API secret
2. Base64 encode the result
3. Compare with `X-Shopify-Hmac-SHA256` header using constant-time comparison

**Critical**: Must use raw body before JSON parsing.

### API Clients

Both GraphQL and REST clients (`lib/nb_shopify.ex:173-247`) expect shop structs with:
- `shop_domain`: The myshopify.com domain
- `access_token`: The offline access token

They use the configured API version (defaults to "2026-01").

## Configuration

Required config keys (in `config/runtime.exs`):
```elixir
config :nb_shopify,
  api_key: System.get_env("SHOPIFY_API_KEY"),      # Shopify API key (client ID)
  api_secret: System.get_env("SHOPIFY_API_SECRET"), # Shopify API secret
  api_version: "2026-01"                             # Shopify API version
```

Optional config for webhook worker:
```elixir
config :nb_shopify, :webhook_handler,
  module: MyApp.ShopifyWebhookHandler,                        # Handler module
  get_shop_by_domain: &MyApp.Shops.get_shop_by_domain/1     # Shop lookup function
```

## Installer Functionality

The Igniter-based installer (`lib/mix/tasks/nb_shopify.install.ex`) can generate:

1. **Configuration** in `config/runtime.exs` (environment-specific)
2. **Router setup** with `:shopify_app` pipeline and example routes
3. **App Bridge setup** in root layout (meta tag + CDN script)
4. **Webhook handler** and controller (with `--with-webhooks`)
5. **Shops context and schema** with migration (with `--with-database`)
6. **Shopify CLI files** (with `--with-cli`): `shopify.app.toml`, `shopify.web.toml`, `.shopify/project.json`
7. **Caddy reverse proxy** for Vite HMR (with `--proxy`)

The installer uses **Igniter** for AST-level code manipulation to avoid brittle string replacements.

## Key Dependencies

- **req** (~> 0.5): HTTP client for API requests
- **joken** (~> 2.6): JWT handling for session tokens
- **plug** (~> 1.14): Plug interface for Phoenix integration
- **jason** (~> 1.2): JSON encoding/decoding
- **phoenix** (~> 1.7): Optional Phoenix integration
- **oban** (~> 2.18): Optional background job processing
- **igniter** (~> 0.6): Optional installer framework

## Security Considerations

1. **Never commit API credentials** - Always use environment variables
2. **Webhook HMAC verification** - Always verify before processing webhooks
3. **Access token storage** - Consider encrypting tokens in database (use Cloak or encrypted_field)
4. **Session validation** - Session tokens are short-lived; always validate expiration
5. **CSRF protection** - Already handled by Phoenix, but verify it's enabled

## Common Patterns

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
```

### Controller Usage
```elixir
def index(conn, _params) do
  shop = conn.assigns.shop  # Assigned by ShopifySession plug

  case NbShopify.graphql(shop, query, variables) do
    {:ok, response} -> # Handle success
    {:error, reason} -> # Handle error
  end
end
```

### Webhook Processing
```elixir
# In webhook controller - verify and enqueue
def create(conn, params) do
  hmac = get_req_header(conn, "x-shopify-hmac-sha256") |> List.first()
  {:ok, raw_body, conn} = Plug.Conn.read_body(conn)

  case NbShopify.verify_webhook_hmac(raw_body, hmac) do
    {:ok, :verified} ->
      %{topic: topic, shop_domain: shop_domain, payload: params}
      |> NbShopify.Workers.WebhookWorker.new()
      |> Oban.insert()

      json(conn, %{status: "ok"})

    {:error, :invalid_hmac} ->
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Invalid HMAC"})
  end
end
```

## API Version Updates

When updating the Shopify API version:
1. Update default in `lib/nb_shopify.ex:60` (currently "2026-01")
2. Update installer default in `lib/mix/tasks/nb_shopify.install.ex:156`
3. Test token exchange and API clients with new version

## Testing Considerations

When writing tests:
- Mock shop structs with `shop_domain` and `access_token` fields
- Use test API credentials from config (see `mix.exs:270-281`)
- Session token verification requires valid JWT with correct signature
- Webhook HMAC verification requires raw body (not parsed JSON)
