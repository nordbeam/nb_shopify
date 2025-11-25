defmodule NbShopify.ConfigError do
  @moduledoc """
  Exception raised when NbShopify configuration is missing or invalid.
  """

  defexception [:message, :key, :environment, :current_config]

  @impl true
  def exception(opts) when is_list(opts) do
    key = Keyword.fetch!(opts, :key)
    custom_message = Keyword.get(opts, :message)
    environment = Keyword.get(opts, :environment, Mix.env())
    current_config = Keyword.get(opts, :current_config, get_current_config())

    message =
      if custom_message do
        build_custom_message(key, custom_message, environment, current_config)
      else
        build_message(key, environment, current_config)
      end

    %__MODULE__{
      message: message,
      key: key,
      environment: environment,
      current_config: current_config
    }
  end

  defp build_custom_message(key, custom_message, environment, current_config) do
    """
    Invalid NbShopify configuration: :#{key}

    #{custom_message}

    Environment: #{environment}
    Current config: #{inspect(current_config)}

    See: https://hexdocs.pm/nb_shopify#configuration
    """
  end

  defp build_message(:api_key, environment, current_config) do
    """
    Shopify API key not configured

    API key is missing for environment '#{environment}'.

    Add this to config/config.exs or config/runtime.exs:

        config :nb_shopify,
          api_key: System.get_env("SHOPIFY_API_KEY"),
          api_secret: System.get_env("SHOPIFY_API_SECRET"),
          api_version: "2026-01"  # optional, defaults to "2026-01"

    For local development, add to .env:

        SHOPIFY_API_KEY=your_key_here
        SHOPIFY_API_SECRET=your_secret_here

    For test environment (config/test.exs):

        config :nb_shopify,
          api_key: "test_api_key",
          api_secret: "test_api_secret"

    Current config: #{inspect(current_config)}

    See: https://hexdocs.pm/nb_shopify#configuration
    """
  end

  defp build_message(:api_secret, environment, current_config) do
    """
    Shopify API secret not configured

    API secret is missing for environment '#{environment}'.

    Add this to config/config.exs or config/runtime.exs:

        config :nb_shopify,
          api_key: System.get_env("SHOPIFY_API_KEY"),
          api_secret: System.get_env("SHOPIFY_API_SECRET"),
          api_version: "2026-01"  # optional, defaults to "2026-01"

    For local development, add to .env:

        SHOPIFY_API_KEY=your_key_here
        SHOPIFY_API_SECRET=your_secret_here

    For test environment (config/test.exs):

        config :nb_shopify,
          api_key: "test_api_key",
          api_secret: "test_api_secret"

    Current config: #{inspect(current_config)}

    See: https://hexdocs.pm/nb_shopify#configuration
    """
  end

  defp build_message(key, environment, current_config) do
    """
    NbShopify configuration error: :#{key}

    Configuration key :#{key} is missing or invalid for environment '#{environment}'.

    Current config: #{inspect(current_config)}

    See: https://hexdocs.pm/nb_shopify#configuration
    """
  end

  defp get_current_config do
    Application.get_all_env(:nb_shopify)
    |> Enum.into(%{})
  end
end
