defmodule NbShopifyWeb.Plugs.ShopifyFrameHeaders do
  @moduledoc """
  Sets security headers to allow Shopify iframe embedding.

  Shopify apps run inside an iframe in the Shopify admin, so we need to:
  1. Allow framing from Shopify domains
  2. Set appropriate Content-Security-Policy

  ## Usage

      defmodule MyAppWeb.Endpoint do
        plug NbShopifyWeb.Plugs.ShopifyFrameHeaders
        # ... other plugs
      end

  Or in a pipeline:

      pipeline :shopify_app do
        plug NbShopifyWeb.Plugs.ShopifyFrameHeaders
      end

  ## What It Does

  - Removes the `x-frame-options` header (which blocks framing)
  - Sets `content-security-policy` to allow framing from:
    - `https://*.myshopify.com` (shop admin)
    - `https://admin.shopify.com` (new admin interface)

  ## Security Note

  This plug is necessary for Shopify embedded apps but should only be used
  for routes that are accessed within the Shopify admin iframe. Consider
  using a separate pipeline for public-facing routes.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> delete_resp_header("x-frame-options")
    |> put_resp_header(
      "content-security-policy",
      "frame-ancestors https://*.myshopify.com https://admin.shopify.com;"
    )
  end
end
