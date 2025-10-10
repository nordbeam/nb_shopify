if Code.ensure_loaded?(Oban) do
  defmodule NbShopify.Workers.WebhookWorker do
    @moduledoc """
    Worker for processing Shopify webhooks asynchronously with Oban.
    Handles webhook payloads in the background to avoid blocking the webhook endpoint.

    ## Usage

    ### 1. Configure Oban

    Add Oban to your application supervision tree:

        children = [
          {Oban, repo: MyApp.Repo, queues: [webhooks: 10]}
        ]

    ### 2. Implement Webhook Handlers

    Create a module that implements webhook handling logic:

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

              _ ->
                Logger.warning("Unhandled webhook topic: \#{topic}")
                :ok
            end
          end

          defp handle_product_create(shop, payload) do
            # Your logic here
            :ok
          end

          # ... more handlers
        end

    ### 3. Configure the Worker

    In your config:

        config :nb_shopify, :webhook_handler,
          module: MyApp.ShopifyWebhookHandler,
          get_shop: &MyApp.Shops.get_shop!/1

    ### 4. Enqueue Jobs from Webhook Controller

        def create(conn, %{"topic" => topic} = params) do
          # Verify HMAC
          if NbShopify.verify_webhook_hmac(conn.assigns.raw_body, hmac) do
            # Enqueue job
            %{
              topic: topic,
              shop_id: shop_id,
              payload: conn.body_params
            }
            |> NbShopify.Workers.WebhookWorker.new()
            |> Oban.insert()

            json(conn, %{status: "ok"})
          end
        end

    ## Configuration

    Required configuration:

        config :nb_shopify, :webhook_handler,
          module: MyApp.ShopifyWebhookHandler,  # Module implementing handle_webhook/3
          get_shop: &MyApp.Shops.get_shop!/1     # Function to fetch shop by ID

    ## Worker Options

    The worker uses the following defaults:
    - Queue: `:webhooks`
    - Max attempts: `5`
    - Priority: `0`

    You can override these when creating jobs:

        %{topic: "products/create", shop_id: 1, payload: %{}}
        |> NbShopify.Workers.WebhookWorker.new(queue: :priority_webhooks, max_attempts: 3)
        |> Oban.insert()
    """

    use Oban.Worker,
      queue: :webhooks,
      max_attempts: 5

    require Logger

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"topic" => topic, "shop_id" => shop_id, "payload" => payload}}) do
      Logger.info("Processing webhook: #{topic} for shop #{shop_id}")

      with {:ok, config} <- get_webhook_config(),
           shop <- config.get_shop.(shop_id) do
        config.module.handle_webhook(topic, shop, payload)
      else
        {:error, :no_config} ->
          Logger.error(
            "Webhook handler not configured. See NbShopify.Workers.WebhookWorker docs."
          )

          {:error, :not_configured}

        error ->
          Logger.error("Failed to process webhook: #{inspect(error)}")
          error
      end
    end

    defp get_webhook_config do
      case Application.get_env(:nb_shopify, :webhook_handler) do
        nil ->
          {:error, :no_config}

        config ->
          module = Keyword.get(config, :module)
          get_shop = Keyword.get(config, :get_shop)

          if module && get_shop do
            {:ok, %{module: module, get_shop: get_shop}}
          else
            {:error, :invalid_config}
          end
      end
    end
  end
else
  defmodule NbShopify.Workers.WebhookWorker do
    @moduledoc """
    Webhook worker stub. Oban is not available.

    To use the webhook worker, add Oban to your dependencies:

        {:oban, "~> 2.18"}

    See the full documentation in the module when Oban is available.
    """

    def new(_args, _opts \\ []) do
      raise """
      NbShopify.Workers.WebhookWorker requires Oban.
      Add to your mix.exs:

          {:oban, "~> 2.18"}
      """
    end
  end
end
