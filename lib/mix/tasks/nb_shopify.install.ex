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
        --proxy              Add Caddy reverse proxy for Vite + Phoenix (recommended with --with-cli)
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

        # With Caddy proxy for better dev experience
        mix nb_shopify.install --with-cli --proxy

        # Custom API version
        mix nb_shopify.install --api-version "2025-10"

    ## What It Does

    1. **Adds Dependencies**:
       - Optionally adds `{:oban, "~> 2.15"}` if --with-webhooks
       - Note: nb_shopify itself is added by `mix igniter.install`

    2. **Configuration**: Creates config in `config/runtime.exs`:
       - Shopify API credentials from environment variables
       - API version configuration
       - Environment-specific settings (dev/test/prod)

    3. **Frontend Dependencies** (if assets/package.json exists):
       - Adds Shopify npm packages to package.json:
         - @shopify/app-bridge (embedded app functionality)
         - @shopify/app-bridge-react (React bindings)
         - @shopify/polaris (Shopify's design system)
         - @shopify/app-bridge-types (TypeScript types)

    4. **Router Setup**: Adds Shopify pipelines to your router:
       - `:shopify_app` pipeline with NbShopifyWeb plugs (library-provided, not generated)
       - NbShopifyWeb.Plugs.ShopifyFrameHeaders for iframe embedding
       - NbShopifyWeb.Plugs.ShopifySession for authentication
       - Example routes for Shopify app

    4.5. **App Bridge Setup**: Adds App Bridge to root layout:
       - Shopify API key meta tag (for App Bridge initialization)
       - App Bridge CDN script (https://cdn.shopify.com/shopifycloud/app-bridge.js)
       - Conditional rendering based on @shopify_api_key assign

    5. **Webhook Support** (--with-webhooks):
       - Creates webhook handler in Web namespace
       - Creates simplified webhook controller (verifies HMAC, enqueues to Oban)
       - Adds webhook routes
       - Configures Oban (if not already configured)

    6. **Database Support** (--with-database):
       - Creates Shops context module
       - Creates Shop schema with fields:
         - shop_domain
         - access_token (encrypted)
         - scope
         - installed_at, uninstalled_at
       - Creates migration
       - Implements CRUD functions for shop management

    7. **Proxy Support** (--proxy):
       - Creates Caddyfile (reverse proxy for Vite + Phoenix)
       - Creates dev.sh script (process manager)
       - Updates shopify.web.toml to use dev.sh
       - Enables HMR through Shopify CLI tunnel
       - Note: Requires manual Vite config update (instructions provided)

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
          proxy: :boolean,
          api_version: :string,
          yes: :boolean
        ],
        defaults: [
          api_version: "2026-01",
          with_cli: false,
          proxy: false
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
      |> configure_endpoint()
      |> configure_dev_environment()
      |> maybe_add_frontend_dependencies()
      |> setup_router()
      |> setup_app_bridge_in_layout()
      |> maybe_setup_webhooks()
      |> maybe_setup_database()
      |> maybe_setup_shopify_cli()
      |> maybe_setup_proxy()
      |> add_security_warnings()
      |> print_next_steps()
    end

    # Add nb_shopify dependency to mix.exs
    defp add_dependencies(igniter) do
      # Don't add nb_shopify itself - it's already added by igniter.install
      # This matches nb_inertia's pattern (see nb_inertia.install.ex line 159)

      if igniter.args.options[:with_webhooks] do
        Igniter.Project.Deps.add_dep(igniter, {:oban, "~> 2.15"})
      else
        igniter
      end
    end

    # Add configuration to config/runtime.exs using Igniter's configure_runtime_env
    defp add_config(igniter) do
      api_version = igniter.args.options[:api_version]

      # Check if nb_shopify config already exists in runtime.exs
      runtime_path = "config/runtime.exs"

      config_exists =
        if File.exists?(runtime_path) do
          content = File.read!(runtime_path)
          String.contains?(content, "config :nb_shopify")
        else
          false
        end

      if config_exists do
        igniter
        |> Igniter.add_notice("""
        NbShopify configuration already exists in config/runtime.exs

        Make sure these environment variables are set:
        - SHOPIFY_API_KEY
        - SHOPIFY_API_SECRET
        """)
      else
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
    end

    # Configure endpoint for embedded Shopify apps
    # Uses AST-based manipulation for robust, formatting-independent updates
    defp configure_endpoint(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)
      web_module = Igniter.Libs.Phoenix.web_module(igniter)
      endpoint_module = Module.concat([web_module, Endpoint])

      igniter
      |> Igniter.Project.Module.find_and_update_module(endpoint_module, fn zipper ->
        with {:ok, zipper} <- Igniter.Code.Module.move_to_module_using(zipper, Phoenix.Endpoint) do
          # Check if same_site is already configured in @session_options
          case Igniter.Code.Module.move_to_attribute_definition(zipper, :session_options) do
            {:ok, attr_zipper} ->
              # Check if same_site is already in the keyword list
              attr_node = Sourceror.Zipper.node(attr_zipper)

              if has_same_site_option?(attr_node) do
                # Already configured, don't modify
                {:ok, zipper}
              else
                # Update existing @session_options with Shopify-required settings
                update_session_options_attribute(zipper, app_name)
              end

            :error ->
              # Add new @session_options attribute
              add_session_options_attribute(zipper, app_name)
          end
        else
          _ ->
            # Can't find Phoenix.Endpoint usage, return unchanged
            {:ok, zipper}
        end
      end)
      |> case do
        {:ok, igniter} ->
          Igniter.add_notice(igniter, """
          Configured endpoint session options for Shopify embedded app:
          - same_site: "None" (required for iframe embedding)
          - secure: true (required for HTTPS in production)

          These settings are MANDATORY for Shopify embedded apps.
          """)

        {:error, igniter} ->
          Igniter.add_warning(igniter, """
          Could not find endpoint module #{inspect(endpoint_module)}

          IMPORTANT: You must manually configure session options for Shopify embedded apps:

          @session_options [
            store: :cookie,
            key: "_#{app_name}_key",
            signing_salt: "your-signing-salt",
            same_site: "None",  # REQUIRED for embedded apps
            secure: true        # REQUIRED for production
          ]
          """)
      end
    end

    # Check if session_options already has same_site configured
    defp has_same_site_option?(attr_node) do
      case attr_node do
        {:@, _, [{:session_options, _, [[{_, _} | _] = keyword_list]}]} ->
          Keyword.has_key?(keyword_list, :same_site)

        _ ->
          false
      end
    end

    # Update existing @session_options attribute
    defp update_session_options_attribute(zipper, app_name) do
      case Igniter.Code.Module.move_to_attribute_definition(zipper, :session_options) do
        {:ok, attr_zipper} ->
          new_options =
            quote do
              [
                store: :cookie,
                key: unquote("_#{app_name}_key"),
                signing_salt: unquote(generate_salt()),
                same_site: "None",
                secure: true
              ]
            end

          updated_zipper = Sourceror.Zipper.replace(attr_zipper, new_options)
          {:ok, updated_zipper}

        :error ->
          {:ok, zipper}
      end
    end

    # Add new @session_options attribute after `use Phoenix.Endpoint`
    defp add_session_options_attribute(zipper, app_name) do
      session_options_code = """
      # Session configuration for Shopify embedded apps
      # same_site: "None" is REQUIRED for embedded apps to work in iframes
      # secure: true is REQUIRED for production HTTPS
      @session_options [
        store: :cookie,
        key: "_#{app_name}_key",
        signing_salt: "#{generate_salt()}",
        same_site: "None",
        secure: true
      ]
      """

      case Igniter.Code.Module.move_to_use(zipper, Phoenix.Endpoint) do
        {:ok, use_zipper} ->
          {:ok, Igniter.Code.Common.add_code(use_zipper, session_options_code, placement: :after)}

        :error ->
          {:ok, zipper}
      end
    end

    # Configure development environment with Bandit settings
    # Note: Uses string manipulation - no AST parser available for config files with complex structures
    defp configure_dev_environment(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)
      web_module = Igniter.Libs.Phoenix.web_module(igniter)
      endpoint_module = Module.concat([web_module, Endpoint])

      # Configure dev.exs with max_header_count
      igniter =
        igniter
        |> Igniter.update_file("config/dev.exs", fn source ->
          content = Rewrite.Source.get(source, :content)

          # Skip if already configured
          if String.contains?(content, "http_1_options") ||
               String.contains?(content, "max_header_count") do
            source
          else
            # Add http_1_options to the http config for the endpoint
            updated_content =
              String.replace(
                content,
                ~r/(config\s+:#{app_name},\s+#{inspect(endpoint_module)}[^[]*\[.*?http:\s*\[)/s,
                "\\1http_1_options: [max_header_count: 200], "
              )

            Rewrite.Source.update(source, :content, fn _ -> updated_content end)
          end
        end)

      # Configure runtime.exs for production
      igniter =
        igniter
        |> Igniter.update_file("config/runtime.exs", fn source ->
          content = Rewrite.Source.get(source, :content)

          # Skip if already configured
          if String.contains?(content, "http_1_options") ||
               String.contains?(content, "max_header_count") do
            source
          else
            # Add http_1_options to the http config for the endpoint in production block
            updated_content =
              String.replace(
                content,
                ~r/(if\s+config_env\(\)\s*==\s*:prod\s+do.*?config\s+:#{app_name},\s+#{inspect(endpoint_module)}[^[]*\[.*?http:\s*\[)/s,
                "\\1http_1_options: [max_header_count: 200], "
              )

            Rewrite.Source.update(source, :content, fn _ -> updated_content end)
          end
        end)

      Igniter.add_notice(igniter, """
      Configured Bandit max_header_count: 200
      - Added to config/dev.exs
      - Added to config/runtime.exs (production)

      This prevents "too many headers" errors from Shopify's OAuth/webhook requests.
      """)
    end

    defp generate_salt do
      :crypto.strong_rand_bytes(8) |> Base.encode64() |> binary_part(0, 8)
    end

    # Add frontend dependencies if package.json exists
    defp maybe_add_frontend_dependencies(igniter) do
      package_json_path = "assets/package.json"

      if File.exists?(package_json_path) do
        add_shopify_npm_packages(igniter, package_json_path)
      else
        igniter
      end
    end

    # Add Shopify npm packages to package.json
    # Note: JSON files require Jason library - no AST manipulation available
    # Using Igniter.update_file with Rewrite.Source is the correct pattern
    defp add_shopify_npm_packages(igniter, package_json_path) do
      igniter
      |> Igniter.update_file(package_json_path, fn source ->
        content = Rewrite.Source.get(source, :content)

        case Jason.decode(content) do
          {:ok, json} ->
            # Use put_in/3 for cleaner nested updates
            updated_json =
              json
              |> put_in(["dependencies", "@shopify/app-bridge"], "^3.7.10")
              |> put_in(["dependencies", "@shopify/app-bridge-react"], "^4.2.4")
              |> put_in(["dependencies", "@shopify/polaris"], "^13.9.5")
              |> put_in(["devDependencies", "@shopify/app-bridge-types"], "^0.5.0")

            case Jason.encode(updated_json, pretty: true) do
              {:ok, new_content} ->
                Rewrite.Source.update(source, :content, fn _ -> new_content <> "\n" end)

              _ ->
                source
            end

          _ ->
            source
        end
      end)
      |> Igniter.add_notice("""
      Added Shopify npm packages to assets/package.json:
      - @shopify/app-bridge (for embedded app functionality)
      - @shopify/app-bridge-react (React bindings for App Bridge)
      - @shopify/polaris (Shopify's design system)
      - @shopify/app-bridge-types (TypeScript types)

      Run your package manager to install:
        cd assets && npm install
      Or:
        cd assets && bun install
      Or:
        cd assets && yarn install
      """)
    end

    # Setup router with Shopify pipelines and routes
    defp setup_router(igniter) do
      web_module = Igniter.Libs.Phoenix.web_module(igniter)
      app_module = Igniter.Project.Module.module_name_prefix(igniter)
      with_database = igniter.args.options[:with_database]

      # Build ShopifySession plug configuration
      session_plug =
        if with_database do
          """
          plug NbShopifyWeb.Plugs.ShopifySession,
            get_shop_by_id: &#{inspect(app_module)}.Shops.get_shop/1,
            get_shop_by_domain: &#{inspect(app_module)}.Shops.get_shop_by_domain/1,
            upsert_shop: &#{inspect(app_module)}.Shops.upsert_shop/1
          """
        else
          """
          # Uncomment and configure when you have a Shop context:
          # plug NbShopifyWeb.Plugs.ShopifySession,
          #   get_shop_by_id: &YourApp.Shops.get_shop/1,
          #   get_shop_by_domain: &YourApp.Shops.get_shop_by_domain/1,
          #   upsert_shop: &YourApp.Shops.upsert_shop/1
          """
        end

      # Add the shopify_app pipeline (just the inner content, not the wrapper)
      pipeline_code = """
      plug :accepts, ["html"]
      plug :fetch_session
      plug :fetch_live_flash
      plug :put_root_layout, html: {#{inspect(web_module)}.Layouts, :root}
      plug :protect_from_forgery
      plug :put_secure_browser_headers
      plug NbShopifyWeb.Plugs.ShopifyFrameHeaders
      #{session_plug}
      """

      # Add example routes (just the inner content, not the scope wrapper)
      routes_code = """
      pipe_through :shopify_app

      get "/", PageController, :index
      """

      # Add router operations
      igniter =
        igniter
        |> Igniter.Libs.Phoenix.add_pipeline(:shopify_app, pipeline_code, [])
        |> Igniter.Libs.Phoenix.add_scope("/", routes_code, alias: web_module)

      notice =
        if with_database do
          """
          Added Shopify pipelines and routes to your router.

          The :shopify_app pipeline includes:
          - NbShopifyWeb.Plugs.ShopifyFrameHeaders for iframe embedding
          - NbShopifyWeb.Plugs.ShopifySession (configured with your Shops context)

          Note: Plugs are provided by the nb_shopify library, not generated in your app.
          """
        else
          """
          Added Shopify pipelines and routes to your router.

          The :shopify_app pipeline includes:
          - NbShopifyWeb.Plugs.ShopifyFrameHeaders for iframe embedding
          - NbShopifyWeb.Plugs.ShopifySession (commented out - configure after setting up Shop context)

          Note: Plugs are provided by the nb_shopify library, not generated in your app.
          To enable ShopifySession, run with --with-database or manually configure it.
          """
        end

      Igniter.add_notice(igniter, notice)
    end

    # Add App Bridge script and API key to root layout
    # Note: HEEx templates require string manipulation - no AST parser available for templates
    # Using Igniter.update_file with Rewrite.Source is the correct Igniter pattern for non-Elixir files
    defp setup_app_bridge_in_layout(igniter) do
      layout_path =
        "lib/#{Igniter.Project.Application.app_name(igniter)}_web/components/layouts/root.html.heex"

      if File.exists?(layout_path) do
        igniter
        |> Igniter.update_file(layout_path, fn source ->
          content = Rewrite.Source.get(source, :content)

          # Check if App Bridge script is already added
          if String.contains?(content, "app-bridge.js") do
            source
          else
            # Find the <head> section and add App Bridge setup after CSRF token
            updated_content =
              String.replace(
                content,
                ~r/(<meta name="csrf-token" content=\{[^}]+\} \/>)/,
                "\\1\n    <%= if assigns[:shopify_api_key] do %>\n      <meta name=\"shopify-api-key\" content={@shopify_api_key} />\n      <script src=\"https://cdn.shopify.com/shopifycloud/app-bridge.js\">\n      </script>\n    <% end %>"
              )

            Rewrite.Source.update(source, :content, fn _ -> updated_content end)
          end
        end)
        |> Igniter.add_notice("""
        Added App Bridge setup to root layout:
        - Shopify API key meta tag (conditional on @shopify_api_key assign)
        - App Bridge CDN script (https://cdn.shopify.com/shopifycloud/app-bridge.js)

        The ShopifySession plug will automatically assign @shopify_api_key for you.
        """)
      else
        igniter
        |> Igniter.add_warning("""
        Could not find root layout at #{layout_path}

        You may need to manually add App Bridge to your layout:

            <%= if assigns[:shopify_api_key] do %>
              <meta name="shopify-api-key" content={@shopify_api_key} />
              <script src="https://cdn.shopify.com/shopifycloud/app-bridge.js">
              </script>
            <% end %>

        Place this in the <head> section after the CSRF token meta tag.
        """)
      end
    end

    # Setup webhooks with Oban worker and controller
    defp maybe_setup_webhooks(igniter) do
      if igniter.args.options[:with_webhooks] do
        igniter
        |> create_webhook_handler()
        |> create_webhook_controller()
        |> create_gdpr_controller()
        |> create_gdpr_context()
        |> add_webhook_routes()
        |> add_gdpr_routes()
        |> configure_webhook_handler()
        |> maybe_configure_oban()
      else
        igniter
      end
    end

    defp create_webhook_handler(igniter) do
      web_module = Igniter.Libs.Phoenix.web_module(igniter)
      handler_module = Module.concat([web_module, ShopifyWebhookHandler])

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

        defp handle_shop_update(shop, _payload) do
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

        Note: Shop lookup is handled by the background worker for faster response time.
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

    defp create_gdpr_controller(igniter) do
      web_module = Igniter.Libs.Phoenix.web_module(igniter)
      app_module = Igniter.Project.Module.module_name_prefix(igniter)
      controller_module = Module.concat([web_module, GdprController])

      content = """
        @moduledoc \"\"\"
        Controller for handling GDPR webhook requests from Shopify.

        These are MANDATORY webhooks required for Shopify App Store approval.
        All Shopify apps must handle these three GDPR endpoints:
        - customers/data_request: Export customer data
        - customers/redact: Delete customer data
        - shop/redact: Delete all shop data (called 48h after uninstall)
        \"\"\"

        use #{inspect(web_module)}, :controller
        alias #{inspect(app_module)}.Gdpr

        require Logger

        @doc \"\"\"
        Handles customers/redact webhook.
        Called when a customer requests their data to be deleted.
        \"\"\"
        def customers_redact(conn, params) do
          shop_domain = params["shop_domain"]
          customer_id = params["customer"]["id"]

          Logger.info("GDPR webhook: customers/redact for shop: \#{shop_domain}")

          {:ok, _} = Gdpr.redact_customer_data(shop_domain, customer_id)
          json(conn, %{success: true})
        end

        @doc \"\"\"
        Handles shop/redact webhook.
        Called 48 hours after a shop uninstalls the app.
        Must delete ALL shop data to comply with GDPR.
        \"\"\"
        def shop_redact(conn, params) do
          shop_domain = params["shop_domain"]

          Logger.info("GDPR webhook: shop/redact for shop: \#{shop_domain}")

          case Gdpr.redact_shop_data(shop_domain) do
            {:ok, _} ->
              json(conn, %{success: true})

            {:error, reason} ->
              Logger.error("GDPR: Failed to redact shop data: \#{inspect(reason)}")

              conn
              |> put_status(:internal_server_error)
              |> json(%{success: false, error: inspect(reason)})
          end
        end

        @doc \"\"\"
        Handles customers/data_request webhook.
        Called when a customer requests their data to be exported.
        \"\"\"
        def customers_data_request(conn, params) do
          shop_domain = params["shop_domain"]
          customer_id = params["customer"]["id"]

          Logger.info("GDPR webhook: customers/data_request for shop: \#{shop_domain}")

          {:ok, data} = Gdpr.export_customer_data(shop_domain, customer_id)
          json(conn, data)
        end
      """

      igniter
      |> Igniter.Project.Module.create_module(controller_module, content)
      |> Igniter.add_notice("""
      Created GDPR controller module #{inspect(controller_module)}

      This controller handles MANDATORY GDPR compliance webhooks from Shopify.
      These webhooks are REQUIRED for App Store approval.
      """)
    end

    defp create_gdpr_context(igniter) do
      app_module = Igniter.Project.Module.module_name_prefix(igniter)
      gdpr_module = Module.concat([app_module, Gdpr])

      content = """
        @moduledoc \"\"\"
        Context for handling GDPR data requests.
        Implements Shopify's mandatory GDPR webhooks.

        IMPORTANT: Customize these functions based on your app's data model.
        The default implementation assumes minimal customer data storage.
        \"\"\"

        # import Ecto.Query  # Uncomment when adding custom query logic
        alias #{inspect(app_module)}.Repo
        alias #{inspect(app_module)}.Shops.Shop

        require Logger

        @doc \"\"\"
        Handles customer data redaction requests.

        Note: Most Shopify apps don't store customer-specific data.
        If your app does store customer data, implement deletion logic here.
        \"\"\"
        def redact_customer_data(shop_domain, customer_id) do
          Logger.info(
            "GDPR: Customer data redaction requested for customer \#{customer_id} from shop \#{shop_domain}"
          )

          # Default implementation: This app doesn't store customer-specific data
          # All data is shop-scoped, not customer-scoped

          # TODO: If your app stores customer data, add deletion logic here
          # Example:
          # from(c in CustomerData, where: c.shop_domain == ^shop_domain and c.customer_id == ^customer_id)
          # |> Repo.delete_all()

          {:ok, :no_customer_data}
        end

        @doc \"\"\"
        Handles shop data redaction requests.
        Deletes ALL shop data including related records.

        This is called 48 hours after a shop uninstalls your app.
        You MUST delete all shop data to comply with GDPR.
        \"\"\"
        def redact_shop_data(shop_domain) do
          case Repo.get_by(Shop, shop_domain: shop_domain) do
            nil ->
              Logger.warning("GDPR: Shop redaction requested for unknown shop: \#{shop_domain}")
              {:ok, :shop_not_found}

            shop ->
              Logger.info("GDPR: Starting shop data redaction for shop \#{shop_domain}")

              Repo.transaction(fn ->
                # TODO: Add deletion logic for all shop-related data
                # Example pattern from a real app:
                # delete_related_data_for_shop(shop.id)

                # Finally, delete the shop itself
                Repo.delete(shop)

                Logger.info("GDPR: Completed shop data redaction for shop \#{shop_domain}")

                :ok
              end)
          end
        end

        @doc \"\"\"
        Handles customer data export requests.
        Returns all data associated with a customer from a specific shop.

        Since most apps don't store customer-specific data, returns minimal info.
        \"\"\"
        def export_customer_data(shop_domain, customer_id) do
          Logger.info(
            "GDPR: Customer data export requested for customer \#{customer_id} from shop \#{shop_domain}"
          )

          # Default implementation: No customer-specific data
          # TODO: If your app stores customer data, export it here

          {:ok,
           %{
             shop_domain: shop_domain,
             customer_id: customer_id,
             data: %{
               note:
                 "This app does not store any customer-specific data. All data is shop-level configuration."
             }
           }}
        end
      """

      igniter
      |> Igniter.Project.Module.create_module(gdpr_module, content)
      |> Igniter.add_notice("""
      Created GDPR context module #{inspect(gdpr_module)}

      This module handles GDPR data deletion and export.
      IMPORTANT: Customize the functions based on your app's data model.
      """)
    end

    defp add_webhook_routes(igniter) do
      web_module = Igniter.Libs.Phoenix.web_module(igniter)

      # Add webhook pipeline (just the inner content)
      webhook_pipeline = """
      plug :accepts, ["json"]
      """

      # Add webhook routes (just the inner content)
      webhook_routes = """
      pipe_through :shopify_webhook

      post "/shopify", WebhookController, :create
      """

      # Add webhook pipeline and routes
      igniter =
        igniter
        |> Igniter.Libs.Phoenix.add_pipeline(:shopify_webhook, webhook_pipeline, [])
        |> Igniter.Libs.Phoenix.add_scope("/webhooks", webhook_routes, alias: web_module)

      Igniter.add_notice(igniter, """
      Added webhook routes to your router.

      Configure your webhook URL in Shopify:
      https://your-domain.com/webhooks/shopify
      """)
    end

    defp add_gdpr_routes(igniter) do
      web_module = Igniter.Libs.Phoenix.web_module(igniter)

      # GDPR routes use the same :shopify_webhook pipeline
      gdpr_routes = """
      pipe_through :shopify_webhook

      post "/customers/redact", GdprController, :customers_redact
      post "/shop/redact", GdprController, :shop_redact
      post "/customers/data_request", GdprController, :customers_data_request
      """

      igniter =
        igniter
        |> Igniter.Libs.Phoenix.add_scope("/webhooks", gdpr_routes, alias: web_module)

      Igniter.add_notice(igniter, """
      Added GDPR routes to your router.

      These routes are MANDATORY for Shopify App Store approval:
      - /webhooks/customers/redact
      - /webhooks/shop/redact
      - /webhooks/customers/data_request

      The GDPR webhooks are already configured in shopify.app.toml.
      """)
    end

    defp configure_webhook_handler(igniter) do
      web_module = Igniter.Libs.Phoenix.web_module(igniter)
      app_module = Igniter.Project.Module.module_name_prefix(igniter)
      handler_module = Module.concat([web_module, ShopifyWebhookHandler])

      config_code = """

      # Webhook handler configuration
      config :nb_shopify, :webhook_handler,
        module: #{inspect(handler_module)},
        get_shop_by_domain: &#{inspect(app_module)}.Shops.get_shop_by_domain/1
      """

      igniter
      |> Igniter.include_or_create_file("config/config.exs", """
      import Config
      """)
      |> Igniter.update_file("config/config.exs", fn source ->
        content = Rewrite.Source.get(source, :content)

        if String.contains?(content, ":webhook_handler") do
          source
        else
          Rewrite.Source.update(source, :content, fn content ->
            content <> "\n" <> config_code
          end)
        end
      end)
    end

    defp maybe_configure_oban(igniter) do
      # Always add Oban config since we're adding the webhook feature
      # User can adjust if they already have Oban configured
      add_oban_config(igniter)
    end

    defp add_oban_config(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)
      repo_module = Module.concat([app_name |> to_string() |> Macro.camelize(), Repo])

      if Igniter.Project.Config.configures_root_key?(igniter, "config.exs", :oban) do
        # Oban config exists - add webhooks queue to existing queues config
        igniter
        |> Igniter.Project.Config.configure(
          "config.exs",
          :oban,
          [:queues],
          {:code,
           quote do
             [webhooks: 20]
           end},
          updater: fn zipper ->
            # Merge webhooks queue into existing queues
            current = Sourceror.Zipper.node(zipper)

            case current do
              {_, _, items} when is_list(items) ->
                # It's a keyword list, add webhooks if not present
                if Keyword.has_key?(items, :webhooks) do
                  {:ok, zipper}
                else
                  new_list = items ++ [webhooks: 20]
                  {:ok, Sourceror.Zipper.replace(zipper, {:{}, [], new_list})}
                end

              _ ->
                {:ok, zipper}
            end
          end
        )
        |> Igniter.add_notice("""
        Added webhooks queue to existing Oban configuration in config.exs
        """)
      else
        # Oban config doesn't exist - create full config
        igniter
        |> Igniter.Project.Config.configure_new(
          "config.exs",
          :oban,
          [:repo],
          {:code,
           quote do
             unquote(repo_module)
           end}
        )
        |> Igniter.Project.Config.configure_new(
          "config.exs",
          :oban,
          [:queues],
          {:code,
           quote do
             [default: 10, webhooks: 20]
           end}
        )
        |> Igniter.Project.Config.configure_new(
          "config.exs",
          :oban,
          [:plugins],
          {:code,
           quote do
             [Oban.Plugins.Pruner]
           end}
        )
        |> Igniter.add_notice("""
        Added Oban configuration to config.exs

        Make sure to:
        1. Run migrations: mix ecto.migrate
        2. Add Oban to your supervision tree if not already present
        """)
      end
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
      app_module = Igniter.Project.Module.module_name_prefix(igniter)
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
          update_shop(shop, %{uninstalled_at: DateTime.utc_now() |> DateTime.truncate(:second)})
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
        def post_install(_shop, is_first_install) do
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
      app_module = Igniter.Project.Module.module_name_prefix(igniter)
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
            put_change(changeset, :installed_at, DateTime.utc_now() |> DateTime.truncate(:second))
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
      timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
      migration_path = "priv/repo/migrations/#{timestamp}_create_shops.exs"

      app_module = Igniter.Project.Module.module_name_prefix(igniter)

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
        |> create_package_json()
        |> create_shopify_app_toml()
        |> create_shopify_web_toml()
        |> create_shopify_directory()
        |> create_env_example()
        |> Igniter.add_notice("""
        Created Shopify CLI configuration files:
        - package.json (for Shopify CLI compatibility)
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

    defp create_package_json(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter) |> to_string()

      content = """
      {
        "name": "#{app_name}",
        "version": "0.1.0",
        "private": true,
        "description": "Phoenix Shopify app",
        "scripts": {
          "dev": "mix phx.server"
        },
        "workspaces": [
          "assets"
        ]
      }
      """

      Igniter.create_new_file(igniter, "package.json", content, on_exists: :skip)
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

      # Declare access scopes required by your app
      # IMPORTANT: Customize these based on your app's needs!
      # See: https://shopify.dev/docs/api/usage/access-scopes
      [access_scopes]
      # Minimal scopes - update based on your requirements
      scopes = "read_products"

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
      with_proxy = igniter.args.options[:proxy]

      dev_command = if with_proxy, do: "./dev.sh", else: "mix phx.server"

      content = """
      # Tells Shopify CLI how to run your Phoenix application
      # https://shopify.dev/docs/apps/tools/cli/configuration#web

      name = "Phoenix"
      roles = ["frontend", "backend"]

      [commands]
      dev = "#{dev_command}"
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

      # Comma-separated list of OAuth scopes (must match shopify.app.toml)
      # Note: Shopify CLI reads this from shopify.app.toml
      # Customize based on your app's needs: https://shopify.dev/docs/api/usage/access-scopes
      export SHOPIFY_SCOPES=read_products

      # Database
      export DATABASE_URL=postgres://postgres:postgres@localhost/#{app_name}_dev

      # Phoenix Secret (generate with: mix phx.gen.secret)
      export SECRET_KEY_BASE=your-secret-key-base-here
      """

      Igniter.create_new_file(igniter, ".env.example", content, on_exists: :skip)
    end

    # Setup Caddy reverse proxy for Vite + Phoenix
    defp maybe_setup_proxy(igniter) do
      if igniter.args.options[:proxy] do
        igniter
        |> create_caddyfile()
        |> create_dev_script()
        |> update_shopify_web_toml()
        |> add_proxy_notices()
      else
        igniter
      end
    end

    defp create_caddyfile(igniter) do
      content = """
      :{$CADDY_PORT:3000} {
      \t# Proxy all Vite requests (everything under /_vite/)
      \thandle /_vite/* {
      \t\treverse_proxy 127.0.0.1:5173
      \t}

      \t# All other requests go to Phoenix (includes WebSocket for LiveView)
      \thandle {
      \t\treverse_proxy 127.0.0.1:4000
      \t}

      \t# Enable CORS for Shopify embedded apps
      \theader {
      \t\tAccess-Control-Allow-Origin *
      \t\tAccess-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS"
      \t\tAccess-Control-Allow-Headers "Content-Type, Authorization"
      \t}

      \t# Disable access logs
      \tlog {
      \t\toutput discard
      \t}
      }
      """

      Igniter.create_new_file(igniter, "Caddyfile", content, on_exists: :skip)
    end

    defp create_dev_script(igniter) do
      content = """
      #!/bin/bash

      # Shopify CLI sets PORT to a random value
      # Caddy should listen on that port, Phoenix on fixed 4000
      export CADDY_PORT=${PORT:-3000}
      export PORT=4000

      # Create a new process group so we can kill all children together
      set -m

      # Cleanup function to kill all child processes
      cleanup() {
          echo "Cleaning up processes..."
          # Kill all processes in this process group
          kill 0 2>/dev/null
          exit
      }

      # Trap SIGINT, SIGTERM, and EXIT
      trap cleanup SIGINT SIGTERM EXIT

      # Start Caddy in the background
      caddy run &
      CADDY_PID=$!

      # Start Phoenix on port 4000 (this blocks)
      # Use exec to replace the shell with Phoenix, so it receives signals directly
      exec mix phx.server
      """

      Igniter.create_new_file(igniter, "dev.sh", content, on_exists: :skip)
    end

    # Update shopify.web.toml to use dev.sh script
    # Note: TOML files require string manipulation - no AST parser available
    # Using Igniter.update_file with Rewrite.Source is the correct Igniter pattern
    # For more robust TOML manipulation, consider adding a TOML library dependency
    defp update_shopify_web_toml(igniter) do
      shopify_web_path = "shopify.web.toml"

      if File.exists?(shopify_web_path) do
        igniter
        |> Igniter.update_file(shopify_web_path, fn source ->
          content = Rewrite.Source.get(source, :content)

          # String replacement is necessary - no TOML AST manipulation tools available
          updated_content =
            content
            |> String.replace(
              ~r/dev = "mix phx\.server"/,
              "dev = \"./dev.sh\""
            )

          Rewrite.Source.update(source, :content, updated_content)
        end)
      else
        igniter
      end
    end

    defp add_proxy_notices(igniter) do
      igniter
      |> Igniter.add_notice("""
      Created Caddy reverse proxy setup:
      - Caddyfile: Proxies /_vite/* to Vite (5173), everything else to Phoenix (4000)
      - dev.sh: Process manager that starts Caddy + Phoenix together
      - shopify.web.toml: Updated to use ./dev.sh for development

      Architecture:
        Shopify CLI → Caddy (port from $PORT or 3000) → Vite (5173) / Phoenix (4000)

      To use:
      1. Install Caddy: https://caddyserver.com/docs/install
      2. Make dev.sh executable: chmod +x dev.sh
      3. Run: shopify app dev (this will now use dev.sh automatically)

      IMPORTANT: You must manually update your Vite config for this setup:

      In assets/vite.config.js (or .ts), update the server config:

      export default defineConfig({
        base: '/_vite/', // Prefix all Vite assets with /_vite for easy proxying
        server: {
          host: process.env.VITE_HOST || "127.0.0.1",
          port: parseInt(process.env.VITE_PORT || "5173"),
          strictPort: true,
          origin: '', // Use relative URLs for assets (works through Caddy proxy and Shopify tunnel)
          allowedHosts: true, // Allow all hosts (needed for dynamic Cloudflare tunnel URLs)
          // HMR auto-detects WebSocket URL from page URL (works with Shopify's HTTPS tunnel)
        },
        // ... rest of your config
      })

      This configuration enables:
      - HMR through Caddy reverse proxy
      - HMR through Shopify CLI's Cloudflare tunnel
      - Single entry point for all requests
      """)
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
          proxy_info =
            if igniter.args.options[:proxy] do
              """

                 Note: With --proxy, this will run ./dev.sh which:
                 - Starts Caddy reverse proxy (routing to Phoenix + Vite)
                 - Enables HMR through the Cloudflare tunnel
              """
            else
              ""
            end

          vite_step =
            if igniter.args.options[:proxy] do
              """

              #{step_counter.count + 1}. Update your Vite config (REQUIRED for --proxy):
                 See the notice above for the exact Vite config changes needed.
                 This enables HMR through Caddy and the Shopify tunnel.

              #{step_counter.count + 2}. #{if igniter.args.options[:with_database], do: "Review", else: "Configure"} your router configuration:
                 #{if igniter.args.options[:with_database] do
                "- NbShopifyWeb.Plugs.ShopifySession is configured with Shops context\n             - Customize routes as needed"
              else
                "- Configure NbShopifyWeb.Plugs.ShopifySession callbacks if needed\n             - Customize routes as needed"
              end}
              """
            else
              """

              #{step_counter.count + 1}. #{if igniter.args.options[:with_database], do: "Review", else: "Configure"} your router configuration:
                 #{if igniter.args.options[:with_database] do
                "- NbShopifyWeb.Plugs.ShopifySession is configured with Shops context\n             - Customize routes as needed"
              else
                "- Configure NbShopifyWeb.Plugs.ShopifySession callbacks if needed\n             - Customize routes as needed"
              end}
              """
            end

          steps = """
          NbShopify has been installed successfully!

          ## Next Steps:

          #{step_counter.count}. Using Shopify CLI (Recommended):

             # Link your app (one-time setup)
             shopify app config link

             # Start development with automatic tunnels and env injection
             shopify app dev
          #{proxy_info}
             This will:
             - Start a Cloudflare tunnel automatically
             - Inject SHOPIFY_API_KEY and SHOPIFY_API_SECRET
             - Update Partner Dashboard URLs automatically
             - Run #{if igniter.args.options[:proxy], do: "./dev.sh (Caddy + Phoenix)", else: "mix phx.server"}

             For manual setup without CLI, see .env.example
          #{vite_step}
          """

          increment = if igniter.args.options[:proxy], do: 3, else: 2
          {steps, %{count: step_counter.count + increment}}
        else
          steps = """
          NbShopify has been installed successfully!

          ## Next Steps:

          #{step_counter.count}. Set your environment variables:
             export SHOPIFY_API_KEY="your-api-key"
             export SHOPIFY_API_SECRET="your-api-secret"

          #{step_counter.count + 1}. #{if igniter.args.options[:with_database], do: "Review", else: "Configure"} your router configuration:
             #{if igniter.args.options[:with_database] do
            "- ShopifySession plug is already configured with Shops context\n             - Customize routes as needed"
          else
            "- Configure ShopifySession plug callbacks if needed\n             - Customize routes as needed"
          end}
          """

          {steps, %{count: step_counter.count + 2}}
        end

      {database_steps, step_counter} =
        if igniter.args.options[:with_database] do
          steps = """

          #{step_counter.count}. Run database migrations:
             mix ecto.migrate
          """

          {steps, %{count: step_counter.count + 1}}
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
             - Edit <AppWeb>.ShopifyWebhookHandler module
             - Add your business logic for each webhook topic
          """

          {steps, %{count: step_counter.count + 2}}
        else
          {"", step_counter}
        end

      start_command =
        cond do
          igniter.args.options[:with_cli] -> "shopify app dev"
          igniter.args.options[:proxy] -> "./dev.sh"
          true -> "mix phx.server"
        end

      final_steps = """

      #{step_counter.count}. Start your Phoenix server:
         #{start_command}

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
