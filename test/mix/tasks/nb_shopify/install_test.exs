defmodule Mix.Tasks.NbShopify.InstallTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.NbShopify.Install

  describe "info/2" do
    test "declares optional webhook dependency" do
      options = Install.installer_options(["--with-webhooks"])

      assert Install.optional_dependency_specs(options, []) == [{:oban, "~> 2.15"}]
    end

    test "parses grouped igniter flags for shared nb task namespaces" do
      options = Install.installer_options(["--nb.with-webhooks"])

      assert Install.optional_dependency_specs(options, []) == [{:oban, "~> 2.15"}]
    end

    test "skips optional dependency when already installed" do
      options = Install.installer_options(["--with-webhooks"])

      assert Install.optional_dependency_specs(options, [:oban]) == []
    end
  end

  describe "frontend dependency installation" do
    test "pins the legacy npm path to Corepack npm 12" do
      assert Install.npm_install_command() ==
               "cd assets && corepack npm@12.0.2 install"
    end
  end
end
