# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.SmartContract.SolcDownloaderTest do
  use ExUnit.Case, async: false

  alias Explorer.SmartContract.SolcDownloader
  alias Plug.Conn

  setup do
    bypass = Bypass.open()
    original_adapter = Application.get_env(:tesla, :adapter)

    original_rust_verifier_configuration =
      Application.get_env(:explorer, Explorer.SmartContract.RustVerifierInterfaceBehaviour)

    original_solc_bin_api_url = Application.get_env(:explorer, :solc_bin_api_url)
    original_state = :sys.get_state(SolcDownloader)

    Application.put_env(:tesla, :adapter, Tesla.Adapter.Mint)
    Application.put_env(:explorer, Explorer.SmartContract.RustVerifierInterfaceBehaviour, enabled: false)
    Application.put_env(:explorer, :solc_bin_api_url, "http://localhost:#{bypass.port}")

    :sys.replace_state(SolcDownloader, fn _state ->
      %{compiler_versions: nil, compiler_versions_fetched_at: nil}
    end)

    on_exit(fn ->
      Application.put_env(:tesla, :adapter, original_adapter)

      Application.put_env(
        :explorer,
        Explorer.SmartContract.RustVerifierInterfaceBehaviour,
        original_rust_verifier_configuration
      )

      Application.put_env(:explorer, :solc_bin_api_url, original_solc_bin_api_url)
      :sys.replace_state(SolcDownloader, fn _state -> original_state end)
    end)

    {:ok, bypass: bypass}
  end

  test "reuses the fetched compiler version list", %{bypass: bypass} do
    Bypass.expect_once(bypass, fn conn ->
      Conn.resp(conn, 200, ~S({"builds": []}))
    end)

    assert SolcDownloader.ensure_exists("v0.0.0+commit.missing") == false
    assert SolcDownloader.ensure_exists("v0.0.1+commit.missing") == false
  end
end
