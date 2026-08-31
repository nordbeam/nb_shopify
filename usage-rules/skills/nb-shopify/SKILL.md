---
name: nb-shopify
description: "Build, configure, migrate, diagnose, and verify nb_shopify embedded Shopify apps, managed installation, webhooks, API clients, and Phoenix plugs."
---

# NbShopify

Use this skill for `nb_shopify` work in a Phoenix/Elixir Shopify app: session-token authentication, Managed Installation token exchange, HMAC webhooks, GraphQL/REST calls, iframe headers, Oban jobs, or the Shopify CLI workflow.

## Discover the target release

- Inspect the target app's `mix.exs`, `mix.lock`, `assets/package.json` and its lockfile, router, endpoint, `config/runtime.exs`, environment templates, and any existing Shop context. Read the selected package's README and `lib/mix/tasks/nb_shopify.install.ex`; do not assume the repository's current API version or installer defaults.
- Preserve optional boundaries: Phoenix integration, Oban webhook processing, Ecto/database scaffolding, frontend packages, Caddy proxy, and Shopify CLI support are separate concerns. Add only what the target release and user's request require.

## Install

- Prefer `mix igniter.install nb_shopify` when Igniter is available, or add the dependency using the version/source chosen for the app and run `mix deps.get` before `mix nb_shopify.install`.
- Use only flags exposed by the selected installer, such as `--with-webhooks`, `--with-database`, `--with-cli`, `--proxy`, `--api-version`, and `--yes`. The default Shopify API version is source-defined and has changed over time; read the task before relying on it.
- Review generated changes before applying them. CLI/proxy options can create `shopify.*.toml`, `.env.example`, Caddy, and development scripts; database/webhook options can create migrations, contexts, controllers, handlers, and Oban configuration.

## Implement and configure

- Keep API credentials and signing secrets in runtime environment variables; never commit them. Validate the app's `:nb_shopify` config and API-version choice for each environment.
- Configure the router pipeline with `NbShopifyWeb.Plugs.ShopifyFrameHeaders` and `NbShopifyWeb.Plugs.ShopifySession`, supplying callbacks for shop lookup/upsert/post-install behavior when the selected plug requires them. Treat `conn.assigns.shop` as authenticated application state only after the plug succeeds.
- Use the package's public verification and client functions (for example `verify_session_token/1`, `verify_webhook_hmac/2`, `graphql/3`, and `rest/4`) as exposed by the target version. Preserve the raw webhook body for HMAC verification and queue work through Oban only when that dependency is installed.
- Add App Bridge/Polaris frontend packages only when an `assets/package.json` exists and the selected installer documents them. When that manifest contains `vite-plus`, install through `vp install`; otherwise preserve the app's existing package manager. Keep access tokens encrypted at rest when using the optional database scaffold.

## Upgrade or migrate

- Before changing versions, compare the lockfile, package changelog/source, Shopify's current API-version schedule, Managed Installation/session-token guidance, and webhook verification requirements. Separate a library upgrade from a Shopify API-version migration.
- Diff generated router, runtime config, CLI files, webhook handlers, schema/migration, and frontend package changes. Preserve callback implementations and app-specific security behavior; do not rerun a full scaffold over customized files without review.
- Exercise install/uninstall and shop-update paths, token expiry, HMAC failures, and API-version behavior after migration. Apply database migrations explicitly when the app uses the generated schema.

## Diagnose and verify

- For configuration errors, inspect runtime environment loading and call the package's config validation path if the target version exposes it. For auth failures, log safe claim/error metadata (never tokens), check issuer/audience/destination/expiry, and confirm the session plug receives the expected header.
- For webhook failures, verify the raw body, `X-Shopify-Hmac-Sha256`, secret, route method/path, and Oban availability. For API failures, inspect shop domain normalization, token scope, API version, request method/path, and response status without printing credentials.
- Verify with `mix deps.get`, `mix compile`, `mix test`, plug tests for valid/invalid JWT and HMAC cases, and a frontend package-manager install/build when frontend integration is enabled. Run `mix ecto.migrate` only in the intended database environment and use Shopify CLI/tunnel smoke tests only with explicit credentials.
- If “latest” is requested, check current Shopify developer documentation for API versions, Managed Installation, session tokens, webhooks, and App Bridge, plus the package's authoritative HexDocs/GitHub source; state the check date and compare with the app lockfile.
