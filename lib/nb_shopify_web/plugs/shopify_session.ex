defmodule NbShopifyWeb.Plugs.ShopifySession do
  @moduledoc """
  Verifies Shopify session for embedded apps with Managed Installation.
  Handles token exchange for first-time installs automatically.

  ## How It Works

  1. Assigns Shopify API key to conn for App Bridge initialization
  2. Check for existing session (returning users)
  3. If no session, look for session token (id_token param or Authorization header)
  4. Validate session token (JWT)
  5. Exchange session token for access token
  6. Call provided callbacks to save shop
  7. Assign shop to conn

  ## Assigns

  - `@shopify_api_key` - The Shopify API key from config (for App Bridge)
  - `@shop` - The shop struct from the database

  ## Configuration

  This plug requires several callbacks to integrate with your application:

      plug NbShopifyWeb.Plugs.ShopifySession,
        get_shop_by_id: &MyApp.Shops.get_shop/1,
        get_shop_by_domain: &MyApp.Shops.get_shop_by_domain/1,
        upsert_shop: &MyApp.Shops.upsert_shop/1,
        post_install: &MyApp.Shops.post_install/2

  ## Callbacks

  - `get_shop_by_id`: `(id :: term()) :: shop | nil`
  - `get_shop_by_domain`: `(domain :: String.t()) :: shop | nil`
  - `upsert_shop`: `(attrs :: map()) :: {:ok, shop} | {:error, term()}`
  - `post_install`: `(shop :: term(), is_first_install :: boolean()) :: :ok | {:ok, term()} | {:error, term()}` (optional)

  **Note**: The `post_install` callback runs synchronously. For long-running tasks
  (webhook registration, data sync), use Oban to enqueue a job instead:

      def post_install(shop, is_first_install) do
        %{shop_id: shop.id, first_install: is_first_install}
        |> MyApp.PostInstallWorker.new()
        |> Oban.insert()
      end

  ## Token Exchange Scenarios

  - **First install**: Exchange token + save shop
  - **Reinstall**: Exchange token + reactivate shop
  - **Scope change**: Exchange token + update scopes
  - **Regular visit**: Use session (no exchange needed)

  ## Example

      defmodule MyAppWeb.Router do
        pipeline :shopify_app do
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

  After this plug runs, `conn.assigns.shop` will contain the authenticated shop.
  """

  import Phoenix.Controller
  import Plug.Conn

  require Logger

  def init(opts) do
    required_callbacks = [:get_shop_by_id, :get_shop_by_domain, :upsert_shop]

    for callback <- required_callbacks do
      unless Keyword.has_key?(opts, callback) do
        raise ArgumentError, "Missing required callback: #{callback}"
      end
    end

    opts
  end

  def call(conn, opts) do
    get_shop_by_id = Keyword.fetch!(opts, :get_shop_by_id)

    # Assign Shopify API key for App Bridge initialization
    conn = assign(conn, :shopify_api_key, Application.get_env(:nb_shopify, :api_key))

    # Try session-based auth first (for returning visits)
    case get_session(conn, :shop_id) do
      nil ->
        # Check for session token in query params (embedded app entry point)
        verify_and_install_if_needed(conn, opts)

      shop_id ->
        # Load shop from session
        case get_shop_by_id.(shop_id) do
          nil ->
            # Session exists but shop doesn't - clear session and retry
            Logger.warning("Shop not found in database", shop_id: shop_id)

            conn
            |> clear_session()
            |> verify_and_install_if_needed(opts)

          shop ->
            assign(conn, :shop, shop)
        end
    end
  end

  defp verify_and_install_if_needed(conn, opts) do
    # Get id_token from query params or Authorization header
    id_token =
      conn.params["id_token"] ||
        case get_req_header(conn, "authorization") do
          ["Bearer " <> token] -> token
          _ -> nil
        end

    case id_token do
      nil ->
        # No token - redirect to root
        conn
        |> put_flash(:error, "Session expired. Please reopen the app.")
        |> redirect(to: "/")
        |> halt()

      token ->
        case NbShopify.verify_session_token(token) do
          {:ok, claims} ->
            shop_domain = extract_shop_domain(claims["dest"])

            # Always perform token exchange to ensure we have a valid access token
            # This handles reinstalls, scope changes, and token refreshes
            install_or_update_shop(conn, shop_domain, token, opts)

          {:error, reason} ->
            Logger.error("Session token verification failed", reason: inspect(reason))

            conn
            |> put_flash(:error, "Invalid session. Please reopen the app.")
            |> redirect(to: "/")
            |> halt()
        end
    end
  end

  defp install_or_update_shop(conn, shop_domain, session_token, opts) do
    get_shop_by_domain = Keyword.fetch!(opts, :get_shop_by_domain)
    upsert_shop = Keyword.fetch!(opts, :upsert_shop)
    post_install = Keyword.get(opts, :post_install)

    existing_shop = get_shop_by_domain.(shop_domain)
    is_first_install = is_nil(existing_shop)

    log_install_type(shop_domain, is_first_install)

    with {:ok, token_data} <- NbShopify.TokenExchange.exchange_token(shop_domain, session_token),
         {:ok, shop} <- save_shop(token_data, shop_domain, upsert_shop) do
      maybe_run_post_install(shop, is_first_install, post_install)

      conn
      |> maybe_put_flash(is_first_install)
      |> put_session(:shop_id, shop.id)
      |> put_session(:shop_domain, shop_domain)
      |> assign(:shop, shop)
    else
      {:error, :save_shop, changeset} ->
        Logger.error("Failed to save shop", error: inspect(changeset))

        conn
        |> put_flash(:error, "Failed to save shop data.")
        |> redirect(to: "/")
        |> halt()

      {:error, reason} ->
        Logger.error("Token exchange failed", reason: inspect(reason))

        conn
        |> put_flash(:error, "Authentication failed. Please try again.")
        |> redirect(to: "/")
        |> halt()
    end
  end

  defp log_install_type(shop_domain, true = _is_first_install) do
    Logger.info("First install", shop: shop_domain)
  end

  defp log_install_type(shop_domain, _is_first_install) do
    Logger.info("Updating access token", shop: shop_domain)
  end

  defp save_shop(token_data, shop_domain, upsert_shop_fn) do
    shop_attrs = %{
      shop_domain: shop_domain,
      access_token: token_data.access_token,
      scope: token_data.scope
    }

    case upsert_shop_fn.(shop_attrs) do
      {:ok, shop} -> {:ok, shop}
      {:error, reason} -> {:error, :save_shop, reason}
    end
  end

  defp maybe_run_post_install(shop, is_first_install, post_install)
       when is_function(post_install) do
    # Run post-install synchronously with proper error handling
    # If you need async processing, use Oban instead of Task.start
    case post_install.(shop, is_first_install) do
      :ok ->
        :ok

      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error("Post-install callback failed",
          shop_id: Map.get(shop, :id),
          shop_domain: Map.get(shop, :shop_domain),
          first_install: is_first_install,
          reason: inspect(reason)
        )

        :ok

      _other ->
        Logger.warning("Post-install callback returned unexpected value",
          shop_id: Map.get(shop, :id),
          shop_domain: Map.get(shop, :shop_domain),
          first_install: is_first_install
        )

        :ok
    end
  end

  defp maybe_run_post_install(_shop, _is_first_install, _post_install), do: :ok

  defp maybe_put_flash(conn, true = _is_first_install) do
    put_flash(conn, :info, "App installed successfully!")
  end

  defp maybe_put_flash(conn, false = _is_first_install), do: conn

  defp extract_shop_domain("https://" <> domain), do: String.trim_trailing(domain, "/")
  defp extract_shop_domain(domain), do: domain
end
