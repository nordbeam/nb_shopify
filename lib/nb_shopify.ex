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

  Boolean indicating whether the HMAC is valid.

  ## Example

      if NbShopify.verify_webhook_hmac(request_body, hmac_header) do
        # Process webhook
      else
        # Reject webhook
      end
  """
  def verify_webhook_hmac(request_body, hmac_header) when is_binary(request_body) do
    computed_hmac =
      :crypto.mac(:hmac, :sha256, api_secret(), request_body)
      |> Base.encode64()

    Plug.Crypto.secure_compare(computed_hmac, hmac_header)
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
    signer = Joken.Signer.create("HS256", api_secret())

    with {:ok, claims} <- Joken.Signer.verify(token, signer),
         :ok <- validate_dest(claims["dest"]),
         :ok <- validate_exp(claims["exp"]),
         :ok <- validate_aud(claims["aud"]) do
      {:ok, claims}
    else
      {:error, reason} = error ->
        Logger.warning("Session token verification failed: #{inspect(reason)}")
        error

      error ->
        Logger.warning("Session token validation failed: #{inspect(error)}")
        {:error, :invalid_token}
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
        Logger.error("Shopify GraphQL request failed: #{status} - #{inspect(body)}")
        {:error, {:request_failed, status}}

      {:error, reason} ->
        Logger.error("Shopify GraphQL request error: #{inspect(reason)}")
        {:error, reason}
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
        Logger.error("Shopify REST request failed: #{status} - #{inspect(body)}")
        {:error, {:request_failed, status}}

      {:error, reason} ->
        Logger.error("Shopify REST request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private helpers

  defp get_config(key, default \\ nil) do
    Application.get_env(:nb_shopify, key, default)
  end

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
