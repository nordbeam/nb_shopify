defmodule NbShopify do
  @moduledoc """
  NbShopify is a reusable Shopify integration library for Elixir applications.

  ## Features

  - Session token (JWT) verification for embedded apps
  - Token exchange for Managed Installation flow
  - Webhook HMAC verification
  - GraphQL and REST API clients
  - Phoenix plugs for authentication and iframe headers
  - Optional Oban worker for webhook processing

  ## Configuration

  Configure your Shopify API credentials in `config/config.exs` or `config/runtime.exs`:

      config :nb_shopify,
        app_name: :my_app,
        api_key: System.get_env("SHOPIFY_API_KEY"),
        api_secret: System.get_env("SHOPIFY_API_SECRET"),
        api_version: "2026-01"

  The `:app_name` is used for fetching configuration from your application's config.
  If not specified, it defaults to `:nb_shopify`.

  ## Usage

  ### Session Token Verification

      case NbShopify.verify_session_token(token) do
        {:ok, claims} -> # Valid token
        {:error, reason} -> # Invalid token
      end

  ### Webhook Verification

      if NbShopify.verify_webhook_hmac(request_body, hmac_header) do
        # Valid webhook
      end

  ### API Requests

      # GraphQL
      NbShopify.graphql(shop, query, variables)

      # REST
      NbShopify.rest(shop, :get, "products.json")

  See individual module documentation for more details.
  """

  require Logger

  @doc """
  Validates that all required configuration is present.

  This function should be called during application startup to catch
  configuration errors early. Returns `:ok` if valid, or raises `NbShopify.ConfigError`.

  ## Example

      # In your application.ex
      defmodule MyApp.Application do
        def start(_type, _args) do
          # Validate NbShopify config at startup
          NbShopify.validate_config!()

          children = [...]
          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end
  """
  def validate_config! do
    required_keys = [:api_key, :api_secret]

    for key <- required_keys do
      value = get_config(key)

      cond do
        is_nil(value) ->
          raise NbShopify.ConfigError, key: key

        not is_binary(value) ->
          raise NbShopify.ConfigError,
            key: key,
            message: "must be a string, got: #{inspect(value)}"

        String.trim(value) == "" ->
          raise NbShopify.ConfigError,
            key: key,
            message: "cannot be empty"

        true ->
          :ok
      end
    end

    # Validate api_version format if provided
    version = api_version()

    unless Regex.match?(~r/^\d{4}-\d{2}$/, version) do
      raise NbShopify.ConfigError,
        key: :api_version,
        message: "must be in format YYYY-MM, got: #{inspect(version)}"
    end

    :ok
  end

  @doc """
  Returns the configured API version.
  Defaults to "2026-01" if not configured.
  """
  def api_version do
    get_config(:api_version, "2026-01")
  end

  @doc """
  Returns the configured API key.
  Raises if not configured.
  """
  def api_key do
    get_config(:api_key) ||
      raise NbShopify.ConfigError, key: :api_key
  end

  @doc """
  Returns the configured API secret.
  Raises if not configured.
  """
  def api_secret do
    get_config(:api_secret) ||
      raise NbShopify.ConfigError, key: :api_secret
  end

  @doc """
  Verifies webhook HMAC from request header.

  ## Parameters

    - request_body: The raw request body as binary
    - hmac_header: The HMAC header value from X-Shopify-Hmac-SHA256

  ## Returns

    - `{:ok, :verified}` if the HMAC is valid
    - `{:error, :invalid_hmac}` if the HMAC is invalid

  ## Example

      case NbShopify.verify_webhook_hmac(request_body, hmac_header) do
        {:ok, :verified} ->
          # Process webhook
        {:error, :invalid_hmac} ->
          # Reject webhook
      end
  """
  def verify_webhook_hmac(request_body, hmac_header) when is_binary(request_body) do
    computed_hmac =
      :crypto.mac(:hmac, :sha256, api_secret(), request_body)
      |> Base.encode64()

    if Plug.Crypto.secure_compare(computed_hmac, hmac_header) do
      {:ok, :verified}
    else
      {:error, :invalid_hmac}
    end
  end

  @doc """
  Validates a Shopify session token (JWT) from embedded app.

  ## Parameters

    - token: The JWT session token from Shopify

  ## Returns

    - `{:ok, claims}` on success with JWT claims map
    - `{:error, reason}` on failure

  ## Example

      case NbShopify.verify_session_token(token) do
        {:ok, %{"dest" => shop_url, "sub" => user_id}} ->
          # Token is valid
        {:error, :token_expired} ->
          # Token has expired
      end
  """
  def verify_session_token(token) do
    # Session tokens are JWTs signed with the app's client secret
    # Cache the signer using persistent_term for performance
    signer = get_or_create_signer()

    with {:ok, claims} <- Joken.Signer.verify(token, signer),
         :ok <- validate_dest(claims["dest"]),
         :ok <- validate_exp(claims["exp"]),
         :ok <- validate_aud(claims["aud"]) do
      {:ok, claims}
    else
      {:error, reason} = error ->
        Logger.warning("Session token verification failed", reason: inspect(reason))
        error
    end
  end

  @doc """
  Makes a GraphQL request to Shopify Admin API.

  ## Parameters

    - shop: Map with `:shop_domain` and `:access_token` keys
    - query: GraphQL query string
    - variables: Map of GraphQL variables (optional)

  ## Returns

    - `{:ok, response}` on success
    - `{:error, reason}` on failure

  ## Example

      query = \"\"\"
      query($id: ID!) {
        product(id: $id) {
          id
          title
        }
      }
      \"\"\"

      NbShopify.graphql(shop, query, %{id: "gid://shopify/Product/123"})
  """
  def graphql(shop, query, variables \\ %{}) do
    with {:ok, _domain} <- validate_shop_domain(shop.shop_domain) do
      url = "https://#{shop.shop_domain}/admin/api/#{api_version()}/graphql.json"

      headers = [
        {"X-Shopify-Access-Token", shop.access_token},
        {"Content-Type", "application/json"}
      ]

      body = %{
        query: query,
        variables: variables
      }

      case Req.post(url, json: body, headers: headers) do
        {:ok, %{status: 200, body: response}} ->
          if Map.has_key?(response, "errors") do
            {:error, {:graphql_errors, response["errors"]}}
          else
            {:ok, response}
          end

        {:ok, %{status: status, body: body}} ->
          Logger.error("GraphQL request failed",
            status: status,
            shop: shop.shop_domain,
            error: inspect(body)
          )

          {:error, {:request_failed, status}}

        {:error, reason} ->
          Logger.error("GraphQL request error",
            shop: shop.shop_domain,
            error: inspect(reason)
          )

          {:error, reason}
      end
    end
  end

  @doc """
  Makes a REST API request to Shopify Admin API.

  ## Parameters

    - shop: Map with `:shop_domain` and `:access_token` keys
    - method: HTTP method (`:get`, `:post`, `:put`, `:delete`)
    - path: API path (without leading slash)
    - body: Request body for POST/PUT (optional)

  ## Returns

    - `{:ok, response}` on success
    - `{:error, reason}` on failure

  ## Example

      NbShopify.rest(shop, :get, "products.json")
      NbShopify.rest(shop, :post, "products.json", %{product: %{title: "New Product"}})
  """
  def rest(shop, method, path, body \\ nil) do
    with {:ok, _domain} <- validate_shop_domain(shop.shop_domain) do
      url = "https://#{shop.shop_domain}/admin/api/#{api_version()}/#{path}"

      headers = [
        {"X-Shopify-Access-Token", shop.access_token},
        {"Content-Type", "application/json"}
      ]

      opts = [headers: headers]
      opts = if body, do: Keyword.put(opts, :json, body), else: opts

      case apply(Req, method, [url, opts]) do
        {:ok, %{status: status, body: response}} when status in 200..299 ->
          {:ok, response}

        {:ok, %{status: status, body: body}} ->
          Logger.error("REST request failed",
            status: status,
            method: method,
            path: path,
            shop: shop.shop_domain,
            error: inspect(body)
          )

          {:error, {:request_failed, status}}

        {:error, reason} ->
          Logger.error("REST request error",
            method: method,
            path: path,
            shop: shop.shop_domain,
            error: inspect(reason)
          )

          {:error, reason}
      end
    end
  end

  # Private helpers

  defp get_config(key, default \\ nil) do
    Application.get_env(:nb_shopify, key, default)
  end

  defp get_or_create_signer do
    # Use persistent_term for fast, read-heavy caching of the signer
    key = {__MODULE__, :signer, api_secret()}

    case :persistent_term.get(key, nil) do
      nil ->
        signer = Joken.Signer.create("HS256", api_secret())
        :persistent_term.put(key, signer)
        signer

      signer ->
        signer
    end
  end

  @doc false
  def validate_shop_domain(domain) when is_binary(domain) do
    cond do
      String.trim(domain) == "" ->
        {:error, :empty_domain}

      String.ends_with?(domain, ".myshopify.com") ->
        {:ok, domain}

      # Allow localhost and custom domains for development/testing
      String.contains?(domain, "localhost") or String.contains?(domain, "127.0.0.1") ->
        {:ok, domain}

      # Reject invalid domains
      true ->
        {:error, :invalid_shop_domain}
    end
  end

  def validate_shop_domain(nil), do: {:error, :missing_domain}
  def validate_shop_domain(_), do: {:error, :invalid_domain_type}

  defp validate_dest(dest) when is_binary(dest) do
    # Validate that dest is a valid myshopify.com domain
    if String.ends_with?(dest, ".myshopify.com") do
      :ok
    else
      {:error, :invalid_dest}
    end
  end

  defp validate_dest(_), do: {:error, :missing_dest}

  defp validate_exp(exp) when is_integer(exp) do
    current_time = System.system_time(:second)

    if exp > current_time do
      :ok
    else
      {:error, :token_expired}
    end
  end

  defp validate_exp(_), do: {:error, :invalid_exp}

  defp validate_aud(aud) when is_binary(aud) do
    if aud == api_key() do
      :ok
    else
      {:error, :invalid_audience}
    end
  end

  defp validate_aud(_), do: {:error, :missing_audience}
end
