# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Indexer.Fetcher.Arbitrum.Utils.RpcTest do
  use EthereumJSONRPC.Case

  import Mox

  alias Indexer.Fetcher.Arbitrum.Utils.Rpc

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{json_rpc_named_arguments: json_rpc_named_arguments} do
    mocked_json_rpc_named_arguments = Keyword.put(json_rpc_named_arguments, :transport, EthereumJSONRPC.Mox)

    %{json_rpc_named_arguments: mocked_json_rpc_named_arguments}
  end

  describe "make_chunked_request_keep_id/3" do
    test "uses unique transport IDs and restores duplicate caller IDs", %{
      json_rpc_named_arguments: json_rpc_named_arguments
    } do
      requests = [
        EthereumJSONRPC.request(%{id: 7, method: "first_method", params: []}),
        EthereumJSONRPC.request(%{id: 7, method: "second_method", params: []})
      ]

      expect(EthereumJSONRPC.Mox, :json_rpc, fn [first_request, second_request], _options ->
        refute first_request.id == second_request.id

        {:ok,
         [
           %{id: second_request.id, jsonrpc: "2.0", result: "second_result"},
           %{id: first_request.id, jsonrpc: "2.0", result: "first_result"}
         ]}
      end)

      assert [
               %{id: 7, result: "second_result"},
               %{id: 7, result: "first_result"}
             ] = Rpc.make_chunked_request_keep_id(requests, json_rpc_named_arguments, "test request")
    end
  end
end
