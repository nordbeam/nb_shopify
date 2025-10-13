if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.NbShopify.Install do
    @moduledoc """
    Installs and configures NbShopify in a Phoenix application using Igniter.

    This installer helps set up a complete Shopify embedded app integration with:
    - API credentials configuration
    - Shopify authentication plugs
    - Optional webhook processing with Oban
    - Optional Shop schema/context for database persistence

    ## Usage

        $ mix nb_shopify.install

    ## Options

        --with-webhooks      Add Oban webhook worker support
        --with-database      Create example Shop schema and context
        --with-cli           Create Shopify CLI config files for `shopify app dev` workflow
        --api-version        Shopify API version (default: "2026-01")
        --yes                Skip confirmations

    ## Examples

        # Basic installation
        mix nb_shopify.install

        # Full installation with webhooks and database
        mix nb_shopify.install --with-webhooks --with-database

        # Installation with Shopify CLI support
        mix nb_shopify.install --with-cli

        # Full installation with CLI, webhooks, and database
        mix nb_shopify.install --with-cli --with-webhooks --with-database

        # Custom API version
        mix nb_shopify.install --api-version "2025-10"

    ## What It Does

    1. **Adds Dependencies**: Adds `{:nb_shopify, "~> 0.1"}` to mix.exs
       - Optionally adds `{:oban, "~> 2.15"}` if --with-webhooks

    2. **Configuration**: Creates config in `config/runtime.exs`:
       - Shopify API credentials from environment variables
       - API version configuration
       - Environment-specific settings (dev/test/prod)

    3. **Router Setup**: Adds Shopify pipelines to your router:
       - `:shopify_app` pipeline with authentication and frame headers
       - Example routes for Shopify app

    4. **Webhook Support** (--with-webhooks):
       - Creates webhook worker example
       - Creates webhook controller
       - Adds webhook routes
       - Configures Oban (if not already configured)

    5. **Database Support** (--with-database):
       - Creates Shops context module
       - Creates Shop schema with fields:
         - shop_domain
         - access_token (encrypted)
         - scope
         - installed_at, uninstalled_at
       - Creates migration
       - Implements CRUD functions for shop management

    ## Security Warnings

    **IMPORTANT**: Never commit your Shopify API credentials to version control!

    - Use environment variables for all secrets
    - Add `.env` to your `.gitignore`
    - Rotate credentials if they are exposed
    - Use encrypted fields for storing access tokens

    ## Next Steps

    After installation:

    1. Set your environment variables:
       ```bash
       export SHOPIFY_API_KEY="your-api-key"
       export SHOPIFY_API_SECRET="your-api-secret"
       ```

    2. If using --with-database:
       ```bash
       mix ecto.migrate
       ```

    3. Update your router callbacks:
       - Implement shop lookup functions
       - Add post-install logic if needed

    4. Configure webhooks (if using --with-webhooks):
       - Implement webhook handler module
       - Subscribe to webhook topics in Shopify

    5. Start your server:
       ```bash
       mix phx.server
       ```

    ## Documentation

    For more information, see:
    - https://github.com/nordbeam/nb/tree/main/nb_shopify
    - https://shopify.dev/docs/apps
    """

    use Igniter.Mix.Task
    require Igniter.Code.Common

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        schema: [
          with_webhooks: :boolean,
          with_database: :boolean,
          with_cli: :boolean,
          api_version: :string,
          yes: :boolean
        ],
        defaults: [
          api_version: "2026-01",
          with_cli: false
        ],
        positional: [],
        composes: ["deps.get"]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> add_dependencies()
      |> add_config()
      |> setup_router()
      |> maybe_setup_webhooks()
      |> maybe_setup_database()
      |> maybe_setup_shopify_cli()
      |> add_security_warnings()
      |> print_next_steps()
    end

    # Add nb_shopify dependency to mix.exs
    defp add_dependencies(igniter) do
      igniter = Igniter.Project.Deps.add_dep(igniter, {:nb_shopify, "~> 0.1"})

      if igniter.args.options[:with_webhooks] do
        Igniter.Project.Deps.add_dep(igniter, {:oban, "~> 2.15"})
      else
        igniter
      end
    end

    # Add configuration to config/runtime.exs using Igniter's configure_runtime_env
    defp add_config(igniter) do
      api_version = igniter.args.options[:api_version]

      igniter
      # Production environment configuration with raises for missing env vars
      |> Igniter.Project.Config.configure_runtime_env(
        :prod,
        :nb_shopify,
        [:api_key],
        {:code,
         quote do
           System.get_env("SHOPIFY_API_KEY") || raise("SHOPIFY_API_KEY not set")
         end}
      )
      |> Igniter.Project.Config.configure_runtime_env(
        :prod,
        :nb_shopify,
        [:api_secret],
        {:code,
         quote do
           System.get_env("SHOPIFY_API_SECRET") || raise("SHOPIFY_API_SECRET not set")
         end}
      )
      |> Igniter.Project.Config.configure_runtime_env(
        :prod,
        :nb_shopify,
        [:api_version],
        api_version
      )
      # Development environment configuration without raises
      |> Igniter.Project.Config.configure_runtime_env(
        :dev,
        :nb_shopify,
        [:api_key],
        {:code,
         quote do
           System.get_env("SHOPIFY_API_KEY")
         end}
      )
      |> Igniter.Project.Config.configure_runtime_env(
        :dev,
        :nb_shopify,
        [:api_secret],
        {:code,
         quote do
           System.get_env("SHOPIFY_API_SECRET")
         end}
      )
      |> Igniter.Project.Config.configure_runtime_env(
        :dev,
        :nb_shopify,
        [:api_version],
        api_version
      )
      # Test environment configuration with static test values
      |> Igniter.Project.Config.configure_runtime_env(
        :test,
        :nb_shopify,
        [:api_key],
        "test_api_key"
      )
      |> Igniter.Project.Config.configure_runtime_env(
        :test,
        :nb_shopify,
        [:api_secret],
        "test_api_secret"
      )
      |> Igniter.Project.Config.configure_runtime_env(
        :test,
        :nb_shopify,
        [:api_version],
        api_version
      )
      |> Igniter.add_notice("""
      Added NbShopify configuration to config/runtime.exs

      Make sure to set these environment variables:
      - SHOPIFY_API_KEY
      - SHOPIFY_API_SECRET
      """)
    end

    # Setup router with Shopify pipelines and routes
    defp setup_router(igniter) do
      web_module = Igniter.Libs.Phoenix.web_module(igniter)

      # Add the shopify_app pipeline
      pipeline_code = """
        pipeline :shopify_app do
          plug :accepts, ["html"]
          plug :fetch_session
          plug :fetch_live_flash
          plug :protect_from_forgery
          plug :put_secure_browser_headers
          plug NbShopifyWeb.Plugs.ShopifyFrameHeaders
          # Uncomment and configure when you have a Shop context:
          # plug NbShopifyWeb.Plugs.ShopifySession,
          #   get_shop_by_id: &MyApp.Shops.get_shop/1,
          #   get_shop_by_domain: &MyApp.Shops.get_shop_by_domain/1,
          #   upsert_shop: &MyApp.Shops.upsert_shop/1
        end
      """

      # Add example routes
      routes_code = """
        scope "/", #{inspect(web_module)} do
          pipe_through :shopify_app

          get "/", PageController, :index
        end
      """

      # Wrap router operations in error handling
      igniter =
        case Igniter.Libs.Phoenix.add_pipeline(igniter, :shopify_app, pipeline_code,
               arg2: web_module
             ) do
          {:error, igniter} ->
            Igniter.add_warning(
              igniter,
              "Could not add Shopify pipeline to router. You may need to manually add the :shopify_app pipeline to #{inspect(web_module)}.Router."
            )

          result ->
            result
        end

      igniter =
        case Igniter.Libs.Phoenix.add_scope(igniter, "/shopify", routes_code, arg2: web_module) do
          {:error, igniter} ->
            Igniter.add_warning(
              igniter,
              "Could not add Shopify routes to router. You may need to manually add the /shopify scope to #{inspect(web_module)}.Router."
            )

          result ->
            result
        end

      Igniter.add_notice(igniter, """
      Added Shopify pipelines and routes to your router.

      The :shopify_app pipeline includes:
      - ShopifyFrameHeaders plug for iframe embedding
      - ShopifySession plug (commented out - configure after setting up Shop context)

      Configure the ShopifySession plug callbacks after creating your Shop context.
      """)
    end

    # Setup webhooks with Oban worker and controller
    defp maybe_setup_webhooks(igniter) do
      if igniter.args.options[:with_webhooks] do
        igniter
        |> create_webhook_handler()
        |> create_webhook_controller()
        |> add_webhook_routes()
        |> configure_webhook_handler()
        |> maybe_configure_oban()
      else
        igniter
      end
    end

    defp create_webhook_handler(igniter) do
      web_module = Igniter.Libs.Phoenix.web_module(igniter)
      app_module = web_module |> Module.split() |> List.first() |> Module.concat(nil)

      handler_module = Module.concat([app_module, ShopifyWebhookHandler])

      content = """
        @moduledoc \"\"\"
        Handles Shopify webhook events.

        Add your webhook handling logic here for different topics.
        \"\"\"

        require Logger

        @doc \"\"\"
        Handles webhook events by topic.

        ## Parameters

          - topic: Webhook topic (e.g., "products/create")
          - shop: Shop struct with access_token and shop_domain
          - payload: Webhook payload as a map

        ## Returns

          - :ok on success
          - {:error, reason} on failure
        \"\"\"
        def handle_webhook(topic, shop, payload) do
          Logger.info("Processing webhook: \#{topic} for shop: \#{shop.shop_domain}")

          case topic do
            "app/uninstalled" ->
              handle_app_uninstalled(shop, payload)

            "shop/update" ->
              handle_shop_update(shop, payload)

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

        defp handle_app_uninstalled(shop, _payload) do
          Logger.info("App uninstalled for shop: \#{shop.shop_domain}")
          # TODO: Mark shop as uninstalled in database
          :ok
        end

        defp handle_shop_update(shop, payload) do
          Logger.info("Shop updated: \#{shop.shop_domain}")
          # TODO: Update shop information
          :ok
        end

        defp handle_product_create(shop, payload) do
          Logger.info("Product created in shop \#{shop.shop_domain}: \#{payload["id"]}")
          # TODO: Handle product creation
          :ok
        end

        defp handle_product_update(shop, payload) do
          Logger.info("Product updated in shop \#{shop.shop_domain}: \#{payload["id"]}")
          # TODO: Handle product update
          :ok
        end

        defp handle_product_delete(shop, payload) do
          Logger.info("Product deleted in shop \#{shop.shop_domain}: \#{payload["id"]}")
          # TODO: Handle product deletion
          :ok
        end
      """

      igniter
      |> Igniter.Project.Module.create_module(handler_module, content)
      |> Igniter.add_notice("""
      Created webhook handler module #{inspect(handler_module)}

      This module handles webhook events from Shopify. Implement your business logic
      in the handle_* functions.
      """)
    end

    defp create_webhook_controller(igniter) do
      web_module = Igniter.Libs.Phoenix.web_module(igniter)
      controller_module = Module.concat([web_module, WebhookController])

      content = """
        use #{inspect(web_module)}, :controller

        require Logger

        @doc \"\"\"
        Handles incoming Shopify webhooks.

        This endpoint:
        1. Verifies the webhook HMAC
        2. Enqueues the webhook for background processing
        3. Returns 200 OK immediately
        \"\"\"
        def create(conn, params) do
          # Get required headers
          hmac = get_req_header(conn, "x-shopify-hmac-sha256") |> List.first()
          topic = get_req_header(conn, "x-shopify-topic") |> List.first()
          shop_domain = get_req_header(conn, "x-shopify-shop-domain") |> List.first()

          # Read raw body for HMAC verification
          {:ok, raw_body, conn} = Plug.Conn.read_body(conn)

          # Verify webhook authenticity
          if NbShopify.verify_webhook_hmac(raw_body, hmac) do
            # Queue webhook for background processing
            %{
              topic: topic,
              shop_domain: shop_domain,
              payload: params
            }
            |> NbShopify.Workers.WebhookWorker.new()
            |> Oban.insert()

            Logger.info("Webhook queued: \#{topic} from \#{shop_domain}")

            json(conn, %{status: "ok"})
          else
            Logger.error("Invalid webhook HMAC from \#{shop_domain}")

            conn
            |> put_status(:unauthorized)
            |> json(%{error: "Invalid HMAC"})
          end
        end
      """

      igniter
      |> Igniter.Project.Module.create_module(controller_module, content)
      |> Igniter.add_notice("""
      Created webhook controller module #{inspect(controller_module)}

      This controller receives and validates webhooks from Shopify, then enqueues
      them for background processing.
      """)
    end

    defp add_webhook_routes(igniter) do
      web_module = Igniter.Libs.Phoenix.web_module(igniter)

      # Add webhook pipeline
      webhook_pipeline = """
        pipeline :shopify_webhook do
          plug :accepts, ["json"]
        end
      """

      # Add webhook routes
      webhook_routes = """
        scope "/webhooks", #{inspect(web_module)} do
          pipe_through :shopify_webhook

          post "/shopify", WebhookController, :create
        end
      """

      # Wrap pipeline addition in error handling
      igniter =
        case Igniter.Libs.Phoenix.add_pipeline(igniter, :shopify_webhook, webhook_pipeline,
               arg2: web_module
             ) do
          {:error, igniter} ->
            Igniter.add_warning(
              igniter,
              "Could not add webhook pipeline to router. You may need to manually add the :shopify_webhook pipeline."
            )

          result ->
            result
        end

      # Wrap scope addition in error handling
      igniter =
        case Igniter.Libs.Phoenix.add_scope(igniter, "/webhooks", webhook_routes,
               arg2: web_module
             ) do
          {:error, igniter} ->
            Igniter.add_warning(
              igniter,
              "Could not add webhook routes to router. You may need to manually add the /webhooks scope."
            )

          result ->
            result
        end

      Igniter.add_notice(igniter, """
      Added webhook routes to your router.

      Configure your webhook URL in Shopify:
      https://your-domain.com/webhooks/shopify
      """)
    end

    defp configure_webhook_handler(igniter) do
      web_module = Igniter.Libs.Phoenix.web_module(igniter)
      app_module = web_module |> Module.split() |> List.first() |> Module.concat(nil)
      handler_module = Module.concat([app_module, ShopifyWebhookHandler])

      config_code = """

      # Webhook handler configuration
      config :nb_shopify, :webhook_handler,
        module: #{inspect(handler_module)},
        get_shop: &#{inspect(app_module)}.Shops.get_shop/1
      """

      # Wrap config file operations in error handling
      igniter =
        igniter
        |> Igniter.include_or_create_file("config/config.exs", """
        import Config
        """)

      case Igniter.update_file(igniter, "config/config.exs", fn source ->
             content = Rewrite.Source.get(source, :content)

             if String.contains?(content, ":webhook_handler") do
               source
             else
               Rewrite.Source.update(source, :content, fn content ->
                 content <> "\n" <> config_code
               end)
             end
           end) do
        {:error, igniter} ->
          Igniter.add_warning(
            igniter,
            "Could not update config/config.exs with webhook handler configuration. You may need to manually add the webhook handler config."
          )

        result ->
          result
      end
    end

    defp maybe_configure_oban(igniter) do
      # Always add Oban config since we're adding the webhook feature
      # User can adjust if they already have Oban configured
      add_oban_config(igniter)
    end

    defp add_oban_config(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)

      oban_config =
        {:code,
         quote do
           [
             repo: unquote(Module.concat([app_name |> to_string() |> Macro.camelize(), Repo])),
             queues: [default: 10, webhooks: 20],
             plugins: [Oban.Plugins.Pruner]
           ]
         end}

      igniter
      |> Igniter.Project.Config.configure("config.exs", :oban, [], oban_config)
      |> Igniter.add_notice("""
      Added Oban configuration to config.exs

      Make sure to:
      1. Run migrations: mix ecto.migrate
      2. Add Oban to your supervision tree if not already present
      """)
    end

    # Setup database with Shop schema and context
    defp maybe_setup_database(igniter) do
      if igniter.args.options[:with_database] do
        igniter
        |> create_shops_context()
        |> create_shop_schema()
        |> create_shop_migration()
      else
        igniter
      end
    end

    defp create_shops_context(igniter) do
      web_module = Igniter.Libs.Phoenix.web_module(igniter)
      app_module = web_module |> Module.split() |> List.first() |> Module.concat(nil)
      context_module = Module.concat([app_module, Shops])

      content = """
        @moduledoc \"\"\"
        The Shops context for managing Shopify shop installations.
        \"\"\"

        import Ecto.Query, warn: false
        alias #{inspect(app_module)}.Repo
        alias #{inspect(context_module)}.Shop

        @doc \"\"\"
        Gets a single shop by ID.

        Returns nil if the Shop does not exist.

        ## Examples

            iex> get_shop(123)
            %Shop{}

            iex> get_shop(456)
            nil

        \"\"\"
        def get_shop(id), do: Repo.get(Shop, id)

        @doc \"\"\"
        Gets a single shop by ID, raising if it doesn't exist.

        ## Examples

            iex> get_shop!(123)
            %Shop{}

            iex> get_shop!(456)
            ** (Ecto.NoResultsError)

        \"\"\"
        def get_shop!(id), do: Repo.get!(Shop, id)

        @doc \"\"\"
        Gets a shop by shop domain.

        ## Examples

            iex> get_shop_by_domain("example.myshopify.com")
            %Shop{}

            iex> get_shop_by_domain("nonexistent.myshopify.com")
            nil

        \"\"\"
        def get_shop_by_domain(shop_domain) do
          Repo.get_by(Shop, shop_domain: shop_domain)
        end

        @doc \"\"\"
        Creates or updates a shop.

        ## Examples

            iex> upsert_shop(%{shop_domain: "example.myshopify.com", access_token: "token"})
            {:ok, %Shop{}}

            iex> upsert_shop(%{shop_domain: nil})
            {:error, %Ecto.Changeset{}}

        \"\"\"
        def upsert_shop(attrs) do
          case get_shop_by_domain(attrs.shop_domain) do
            nil ->
              %Shop{}
              |> Shop.changeset(attrs)
              |> Repo.insert()

            shop ->
              shop
              |> Shop.changeset(attrs)
              |> Repo.update()
          end
        end

        @doc \"\"\"
        Updates a shop.

        ## Examples

            iex> update_shop(shop, %{access_token: "new_token"})
            {:ok, %Shop{}}

            iex> update_shop(shop, %{shop_domain: nil})
            {:error, %Ecto.Changeset{}}

        \"\"\"
        def update_shop(%Shop{} = shop, attrs) do
          shop
          |> Shop.changeset(attrs)
          |> Repo.update()
        end

        @doc \"\"\"
        Marks a shop as uninstalled.

        ## Examples

            iex> uninstall_shop(shop)
            {:ok, %Shop{}}

        \"\"\"
        def uninstall_shop(%Shop{} = shop) do
          update_shop(shop, %{uninstalled_at: DateTime.utc_now()})
        end

        @doc \"\"\"
        Lists all active (installed) shops.

        ## Examples

            iex> list_active_shops()
            [%Shop{}, ...]

        \"\"\"
        def list_active_shops do
          Shop
          |> where([s], is_nil(s.uninstalled_at))
          |> Repo.all()
        end

        @doc \"\"\"
        Post-install callback that can be customized for your app.

        Called after a shop is successfully installed or reinstalled.

        ## Examples

            iex> post_install(shop, true)
            :ok

        \"\"\"
        def post_install(shop, is_first_install) do
          if is_first_install do
            # First time installation
            # TODO: Create default data, subscribe to webhooks, etc.
            :ok
          else
            # Reinstallation or scope update
            # TODO: Update webhooks, refresh data, etc.
            :ok
          end
        end
      """

      igniter
      |> Igniter.Project.Module.create_module(context_module, content)
      |> Igniter.add_notice("""
      Created Shops context module #{inspect(context_module)}

      This context provides functions for managing shop installations.
      """)
    end

    defp create_shop_schema(igniter) do
      web_module = Igniter.Libs.Phoenix.web_module(igniter)
      app_module = web_module |> Module.split() |> List.first() |> Module.concat(nil)
      schema_module = Module.concat([app_module, Shops, Shop])

      content = """
        @moduledoc \"\"\"
        Schema for Shopify shop installations.
        \"\"\"

        use Ecto.Schema
        import Ecto.Changeset

        @primary_key {:id, :binary_id, autogenerate: true}
        @foreign_key_type :binary_id

        schema "shops" do
          field :shop_domain, :string
          field :access_token, :string
          field :scope, :string
          field :installed_at, :utc_datetime
          field :uninstalled_at, :utc_datetime

          timestamps(type: :utc_datetime)
        end

        @doc false
        def changeset(shop, attrs) do
          shop
          |> cast(attrs, [:shop_domain, :access_token, :scope, :installed_at, :uninstalled_at])
          |> validate_required([:shop_domain, :access_token, :scope])
          |> unique_constraint(:shop_domain)
          |> validate_format(:shop_domain, ~r/^[a-zA-Z0-9][a-zA-Z0-9\-]*\.myshopify\.com$/)
          |> maybe_set_installed_at()
        end

        defp maybe_set_installed_at(changeset) do
          if get_change(changeset, :installed_at) == nil and
               get_field(changeset, :installed_at) == nil do
            put_change(changeset, :installed_at, DateTime.utc_now())
          else
            changeset
          end
        end
      """

      igniter
      |> Igniter.Project.Module.create_module(schema_module, content)
      |> Igniter.add_notice("""
      Created Shop schema module #{inspect(schema_module)}

      The schema includes:
      - shop_domain (unique)
      - access_token (should be encrypted in production)
      - scope
      - installed_at / uninstalled_at timestamps
      """)
    end

    defp create_shop_migration(igniter) do
      timestamp = DateTime.utc_now() |> DateTime.to_unix() |> to_string()
      migration_path = "priv/repo/migrations/#{timestamp}_create_shops.exs"

      web_module = Igniter.Libs.Phoenix.web_module(igniter)
      app_module = web_module |> Module.split() |> List.first() |> Module.concat(nil)

      content = """
      defmodule #{inspect(app_module)}.Repo.Migrations.CreateShops do
        use Ecto.Migration

        def change do
          create table(:shops, primary_key: false) do
            add :id, :binary_id, primary_key: true
            add :shop_domain, :string, null: false
            add :access_token, :string, null: false
            add :scope, :string, null: false
            add :installed_at, :utc_datetime
            add :uninstalled_at, :utc_datetime

            timestamps(type: :utc_datetime)
          end

          create unique_index(:shops, [:shop_domain])
        end
      end
      """

      igniter
      |> Igniter.create_new_file(migration_path, content)
      |> Igniter.add_notice("""
      Created migration at #{migration_path}

      Run 'mix ecto.migrate' to create the shops table.

      SECURITY NOTE: Consider encrypting the access_token field in production.
      You can use libraries like Cloak or encrypted_field for this.
      """)
    end

    # Setup Shopify CLI configuration files
    defp maybe_setup_shopify_cli(igniter) do
      if igniter.args.options[:with_cli] do
        igniter
        |> create_shopify_app_toml()
        |> create_shopify_web_toml()
        |> create_shopify_directory()
        |> create_env_example()
        |> Igniter.add_notice("""
        Created Shopify CLI configuration files:
        - shopify.app.toml (app configuration)
        - shopify.web.toml (web process configuration)
        - .shopify/project.json (CLI project metadata)
        - .env.example (environment variable template)

        To use Shopify CLI:
        1. Install Shopify CLI: npm install -g @shopify/cli@latest
        2. Link your app: shopify app config link
        3. Start development: shopify app dev

        The CLI will automatically handle tunnels and inject environment variables.
        """)
      else
        igniter
      end
    end

    defp create_shopify_app_toml(igniter) do
      api_version = igniter.args.options[:api_version]
      app_name = Igniter.Project.Application.app_name(igniter) |> to_string()

      content = """
      # Learn more about configuring your app at https://shopify.dev/docs/apps/tools/cli/configuration

      # This will be set when you run: shopify app config link
      # client_id = ""

      name = "#{app_name}"
      application_url = "https://shopify.dev/apps/default-app-home"
      embedded = true

      [build]
      automatically_update_urls_on_dev = true
      include_config_on_deploy = true

      # Declare access scopes
      # Customize based on your app's needs: https://shopify.dev/docs/api/usage/access-scopes
      [access_scopes]
      scopes = "read_products,write_products"

      # Webhooks configuration
      # The CLI will automatically register these webhooks
      [webhooks]
      api_version = "#{api_version}"

      # GDPR compliance webhooks (required by Shopify for all apps)
      [[webhooks.subscriptions]]
      compliance_topics = ["customers/data_request"]
      uri = "/webhooks/shopify"

      [[webhooks.subscriptions]]
      compliance_topics = ["customers/redact"]
      uri = "/webhooks/shopify"

      [[webhooks.subscriptions]]
      compliance_topics = ["shop/redact"]
      uri = "/webhooks/shopify"

      [auth]
      redirect_urls = [
        "https://shopify.dev/apps/default-app-home/auth/callback",
        "https://shopify.dev/apps/default-app-home/auth/shopify/callback",
        "https://shopify.dev/apps/default-app-home/api/auth"
      ]
      """

      Igniter.create_new_file(igniter, "shopify.app.toml", content, on_exists: :skip)
    end

    defp create_shopify_web_toml(igniter) do
      content = """
      # Tells Shopify CLI how to run your Phoenix application
      # https://shopify.dev/docs/apps/tools/cli/configuration#web

      name = "Phoenix"
      roles = ["frontend", "backend"]

      [commands]
      dev = "mix phx.server"
      """

      Igniter.create_new_file(igniter, "shopify.web.toml", content, on_exists: :skip)
    end

    defp create_shopify_directory(igniter) do
      igniter
      |> Igniter.create_new_file(".shopify/project.json", "{}", on_exists: :skip)
      |> Igniter.create_new_file(
        ".shopify/.gitignore",
        """
        # Shopify CLI generates these files
        dev-bundle/
        dev-bundle.br
        """,
        on_exists: :skip
      )
    end

    defp create_env_example(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter) |> to_string()

      content = """
      # Shopify App Configuration
      # ===========================
      #
      # IMPORTANT: This file is only needed if you're NOT using Shopify CLI.
      #
      # If using `shopify app dev`, the CLI automatically injects:
      #   - SHOPIFY_API_KEY
      #   - SHOPIFY_API_SECRET
      #   - HOST (tunnel URL)
      #   - PORT
      #   - SCOPES
      #
      # For manual setup (without CLI), copy this to .env and fill in values.

      # Get these from your Shopify Partner Dashboard
      export SHOPIFY_API_KEY=your-api-key-here
      export SHOPIFY_API_SECRET=your-api-secret-here

      # Update this with your ngrok/tunnel URL during development
      # Note: Shopify CLI sets this automatically via HOST variable
      export SHOPIFY_REDIRECT_URI=http://localhost:4000/auth/callback

      # Comma-separated list of OAuth scopes
      # Note: Shopify CLI reads this from shopify.app.toml
      export SHOPIFY_SCOPES=read_products,write_products

      # Database
      export DATABASE_URL=postgres://postgres:postgres@localhost/#{app_name}_dev

      # Phoenix Secret (generate with: mix phx.gen.secret)
      export SECRET_KEY_BASE=your-secret-key-base-here
      """

      Igniter.create_new_file(igniter, ".env.example", content, on_exists: :skip)
    end

    # Add security warnings
    defp add_security_warnings(igniter) do
      Igniter.add_warning(igniter, """
      SECURITY REMINDER:

      1. Never commit Shopify API credentials to version control
      2. Always use environment variables for secrets
      3. Add .env to your .gitignore file
      4. Consider encrypting access_token field in database
      5. Rotate credentials immediately if exposed
      6. Use HTTPS in production
      7. Validate all webhook payloads

      For production deployments:
      - Use strong secret_key_base
      - Enable CSRF protection
      - Configure proper CORS headers
      - Monitor for suspicious activity
      """)
    end

    # Print next steps
    defp print_next_steps(igniter) do
      step_counter = %{count: 1}

      {base_steps, step_counter} =
        if igniter.args.options[:with_cli] do
          steps = """
          NbShopify has been installed successfully!

          ## Next Steps:

          #{step_counter.count}. Using Shopify CLI (Recommended):

             # Link your app (one-time setup)
             shopify app config link

             # Start development with automatic tunnels and env injection
             shopify app dev

             This will:
             - Start a Cloudflare tunnel automatically
             - Inject SHOPIFY_API_KEY and SHOPIFY_API_SECRET
             - Update Partner Dashboard URLs automatically
             - Run mix phx.server

             For manual setup without CLI, see .env.example

          #{step_counter.count + 1}. Update your router configuration:
             - Configure ShopifySession plug callbacks
             - Customize routes as needed
          """

          {steps, %{count: step_counter.count + 2}}
        else
          steps = """
          NbShopify has been installed successfully!

          ## Next Steps:

          #{step_counter.count}. Set your environment variables:
             export SHOPIFY_API_KEY="your-api-key"
             export SHOPIFY_API_SECRET="your-api-secret"

          #{step_counter.count + 1}. Update your router configuration:
             - Configure ShopifySession plug callbacks
             - Customize routes as needed
          """

          {steps, %{count: step_counter.count + 2}}
        end

      {database_steps, step_counter} =
        if igniter.args.options[:with_database] do
          steps = """

          #{step_counter.count}. Run database migrations:
             mix ecto.migrate

          #{step_counter.count + 1}. Update ShopifySession plug in router.ex:
             Uncomment and configure the plug with your Shops context functions
          """

          {steps, %{count: step_counter.count + 2}}
        else
          {"", step_counter}
        end

      {webhook_steps, step_counter} =
        if igniter.args.options[:with_webhooks] do
          steps = """

          #{step_counter.count}. Configure webhooks in Shopify Partner Dashboard:
             - Set webhook URL: https://your-domain.com/webhooks/shopify
             - Subscribe to required topics (e.g., app/uninstalled, products/create)

          #{step_counter.count + 1}. Implement webhook handlers:
             - Edit ShopifyWebhookHandler module
             - Add your business logic for each webhook topic
          """

          {steps, %{count: step_counter.count + 2}}
        else
          {"", step_counter}
        end

      final_steps = """

      #{step_counter.count}. Start your Phoenix server:
         #{if igniter.args.options[:with_cli], do: "shopify app dev", else: "mix phx.server"}

      ## Documentation:

      - NbShopify: https://github.com/nordbeam/nb/tree/main/nb_shopify
      - Shopify App Development: https://shopify.dev/docs/apps
      - Managed Installation: https://shopify.dev/docs/apps/auth/oauth/managed-install
      #{if igniter.args.options[:with_cli], do: "- Shopify CLI: https://shopify.dev/docs/apps/tools/cli", else: ""}

      ## Troubleshooting:

      If you encounter issues:
      - Check that environment variables are set correctly
      - Verify your Shopify app configuration
      - Review logs for authentication errors
      - Ensure your app URL is accessible from Shopify
      #{if igniter.args.options[:with_cli], do: "- For CLI issues, see: shopify app dev --help", else: ""}
      """

      Igniter.add_notice(igniter, base_steps <> database_steps <> webhook_steps <> final_steps)
    end
  end
else
  # Fallback if Igniter is not installed
  defmodule Mix.Tasks.NbShopify.Install do
    @shortdoc "Installs NbShopify | Install `igniter` to use"
    @moduledoc """
    The task 'nb_shopify.install' requires igniter for advanced installation features.

    To use the full installer with automatic configuration, install igniter:

        {:igniter, "~> 0.6", only: [:dev]}

    Then run:

        mix deps.get
        mix nb_shopify.install

    For manual installation, see:
    https://github.com/nordbeam/nb/tree/main/nb_shopify#installation
    """

    use Mix.Task

    def run(_argv) do
      Mix.shell().info("""
      The task 'nb_shopify.install' requires igniter for automatic installation.

      Add igniter to your mix.exs:

          {:igniter, "~> 0.6", only: [:dev]}

      Then run:

          mix deps.get
          mix nb_shopify.install
      """)
    end
  end
end
