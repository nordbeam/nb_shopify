defmodule NbShopify.TokenExchange do
  @moduledoc """
  Handles token exchange for Shopify Managed Installation.
  Exchanges session tokens (JWT) for access tokens.

  This replaces the old OAuth authorization code grant flow introduced
  with Shopify's Managed Installation feature.

  ## Usage

      case NbShopify.TokenExchange.exchange_token(shop_domain, session_token) do
        {:ok, %{access_token: token, scope: scope}} ->
          # Save token and proceed
        {:error, reason} ->
          # Handle error
      end

  ## Token Types

  - **Session Token (ID Token)**: Short-lived JWT issued by Shopify
  - **Access Token**: Long-lived offline access token for API requests

  The token exchange process converts the session token into an access token
  that can be stored and used for subsequent API requests.
  """

  require Logger

  @doc """
  Exchanges a session token for an access token.

  ## Parameters

    - shop_domain: The shop's myshopify.com domain
    - session_token: The JWT session token from Shopify

  ## Returns

    - `{:ok, %{access_token: token, scope: scope}}` on success
    - `{:error, reason}` on failure

  ## Example

      iex> NbShopify.TokenExchange.exchange_token("example.myshopify.com", jwt_token)
      {:ok, %{access_token: "shpat_...", scope: "read_products,write_products"}}

  ## Error Responses

    - `{:error, {:exchange_failed, status}}` - HTTP error from Shopify
    - `{:error, reason}` - Network or other error
  """
  def exchange_token(shop_domain, session_token) do
    url = "https://#{shop_domain}/admin/oauth/access_token"

    body = %{
      client_id: NbShopify.api_key(),
      client_secret: NbShopify.api_secret(),
      grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
      subject_token: session_token,
      subject_token_type: "urn:ietf:params:oauth:token-type:id_token",
      requested_token_type: "urn:shopify:params:oauth:token-type:offline-access-token"
    }

    case Req.post(url, json: body) do
      {:ok, %{status: 200, body: response}} ->
        Logger.info("Token exchange successful for shop: #{shop_domain}")

        {:ok,
         %{
           access_token: response["access_token"],
           scope: response["scope"]
         }}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Token exchange failed for #{shop_domain}: #{status} - #{inspect(body)}")
        {:error, {:exchange_failed, status}}

      {:error, reason} ->
        Logger.error("Token exchange request error for #{shop_domain}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
