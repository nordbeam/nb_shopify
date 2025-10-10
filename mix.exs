defmodule NbShopify.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/assim-fayas/nb"

  def project do
    [
      app: :nb_shopify,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "NbShopify",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # HTTP client for Shopify API requests
      {:req, "~> 0.5"},
      # JWT handling for session tokens
      {:joken, "~> 2.6"},
      # Plug support for Phoenix integration
      {:plug, "~> 1.14"},
      # JSON encoding/decoding
      {:jason, "~> 1.2"},
      # Optional: Phoenix integration for plugs
      {:phoenix, "~> 1.7", optional: true},
      # Optional: Background job processing for webhooks
      {:oban, "~> 2.18", optional: true},

      # Dev/Test dependencies
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.5", only: [:dev], runtime: false}
    ]
  end

  defp description do
    """
    A reusable Shopify integration library for Elixir applications.
    Provides authentication, webhooks, GraphQL/REST API clients, and Phoenix plugs.
    """
  end

  defp package do
    [
      name: "nb_shopify",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end
end
