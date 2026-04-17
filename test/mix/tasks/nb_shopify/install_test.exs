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
end
