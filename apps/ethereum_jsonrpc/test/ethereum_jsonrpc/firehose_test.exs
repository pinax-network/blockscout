# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule EthereumJSONRPC.FirehoseTest do
  use ExUnit.Case, async: true

  import Mox

  alias EthereumJSONRPC.{Blocks, Firehose}

  setup :verify_on_exit!

  setup do
    Application.put_env(:ethereum_jsonrpc, Firehose, url: "http://firehose-sidecar.test/v1/blocks", http_options: [])
    on_exit(fn -> Application.delete_env(:ethereum_jsonrpc, Firehose) end)
    :ok
  end

  # Captured verbatim from a sidecar backed by a devnet: one block with a value transfer into a
  # contract that forwards the value on, so the trace carries a nested call.
  @block_hash "0x792b1b599d9cf5197d5db8f9c94c0d78b8f329a427319be4341e110306589954"
  @transaction_hash "0xa076bfc95262ede0b10a7d1b6be0ca08c55aa440f247b8f4701b9672e5c243b8"
  @from "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
  @forwarder "0x5fbdb2315678afecb367f032d93f642f64180aa3"
  @recipient "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
  @empty_bloom "0x" <> String.duplicate("0", 512)

  defp entry(number) do
    %{
      "number" => number,
      "block" => %{
        "hash" => @block_hash,
        "parentHash" => "0xf62cfff27837fd3ea6e42e47112f26c6db2e8fd161c2165368a36169b80b4437",
        "sha3Uncles" => "0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347",
        "miner" => "0x0000000000000000000000000000000000000000",
        "stateRoot" => "0x12dafe23f8287c78bd53867e0378fd2fd000dcba6722f267f8b67f09ed4051cf",
        "transactionsRoot" => "0x39eedd1248d9e08ad796b6e0114d63b1ff8bcc0fc56fdb049677bca9a6cf163c",
        "receiptsRoot" => "0xbd63688fd40783b0e633f4150b9b79efd07cfe019990cd2b84f873ad08a2376b",
        "logsBloom" => @empty_bloom,
        "difficulty" => "0x0",
        "number" => "0x" <> Integer.to_string(number, 16),
        "gasLimit" => "0x1c9c380",
        "gasUsed" => "0x766f",
        "timestamp" => "0x6a6f1b36",
        "extraData" => "0x",
        "mixHash" => "0xa57a776bd4adad1acb12b27527f45aadf3f25c8f19f750ab3ed691c161a431e3",
        "nonce" => "0x0000000000000000",
        "baseFeePerGas" => "0x36402",
        "totalDifficulty" => "0x0",
        "size" => "0x2dc",
        "uncles" => [],
        "withdrawals" => [],
        "transactions" => [
          %{
            "type" => "0x2",
            "nonce" => "0x1",
            "gas" => "0x7f6b",
            "to" => @forwarder,
            "value" => "0x2386f26fc10000",
            "input" => "0x",
            "hash" => @transaction_hash,
            "blockHash" => @block_hash,
            "blockNumber" => "0x" <> Integer.to_string(number, 16),
            "transactionIndex" => "0x0",
            "from" => @from,
            "gasPrice" => "0x36403"
          }
        ]
      },
      "receipts" => [
        %{
          "type" => "0x2",
          "status" => "0x1",
          "cumulativeGasUsed" => "0x766f",
          "logs" => [],
          "logsBloom" => @empty_bloom,
          "transactionHash" => @transaction_hash,
          "transactionIndex" => "0x0",
          "blockHash" => @block_hash,
          "blockNumber" => "0x" <> Integer.to_string(number, 16),
          "gasUsed" => "0x766f",
          "effectiveGasPrice" => "0x36403",
          "from" => @from,
          "to" => @forwarder,
          "contractAddress" => nil
        }
      ],
      "balanceChanges" => [
        %{"address" => @from, "value" => "0x2e85d789c5e1b"},
        %{"address" => @forwarder, "value" => "0x0"}
      ],
      "traces" => [
        %{
          "txHash" => @transaction_hash,
          "result" => %{
            "from" => @from,
            "gas" => "0x2d63",
            "gasUsed" => "0x766f",
            "to" => @forwarder,
            "input" => "0x",
            "value" => "0x2386f26fc10000",
            "type" => "CALL",
            "calls" => [
              %{
                "from" => @forwarder,
                "gas" => "0x8fc",
                "gasUsed" => "0x0",
                "to" => @recipient,
                "input" => "0x",
                "value" => "0x2386f26fc10000",
                "type" => "CALL"
              }
            ]
          }
        }
      ]
    }
  end

  # Stubs the sidecar and captures the request body it was sent.
  defp stub_sidecar(entries, status \\ 200) do
    test = self()

    expect(Explorer.Mock.TeslaAdapter, :call, fn %Tesla.Env{body: body} = env, _opts ->
      send(test, {:sidecar_request, Jason.decode!(body)})
      {:ok, %Tesla.Env{env | status: status, body: Jason.encode!(%{"blocks" => entries})}}
    end)
  end

  describe "fetch_range/1" do
    test "returns blocks, receipts and internal transactions from one request" do
      stub_sidecar([entry(64)])

      assert {:ok, %{blocks: blocks, receipts: receipts, internal_transactions: internal_transactions}} =
               Firehose.fetch_range(64..64)

      assert %Blocks{blocks_params: [block_params], transactions_params: [transaction_params], errors: []} = blocks
      assert block_params.number == 64
      assert to_string(block_params.hash) == @block_hash
      assert to_string(transaction_params.hash) == @transaction_hash

      # receipts come back in the shape `Indexer.Block.Fetcher.Receipts.put/2` consumes
      assert %{logs: [], receipts: [receipt_params]} = receipts
      assert to_string(receipt_params.transaction_hash) == @transaction_hash
      assert receipt_params.status == :ok

      # the nested CALL is what the node's tracer would otherwise have had to supply
      assert length(internal_transactions) == 2
      assert Enum.all?(internal_transactions, &(&1.block_number == 64))
      assert [_top_level, nested] = Enum.sort_by(internal_transactions, & &1.index)
      assert to_string(nested.from_address_hash) == @forwarder
      assert to_string(nested.to_address_hash) == @recipient
    end

    test "asks the sidecar for an ascending span when the range descends" do
      # the catchup fetcher walks backwards, so it hands down ranges like 70..61
      stub_sidecar(Enum.map(61..70, &entry/1))

      assert {:ok, _range_data} = Firehose.fetch_range(70..61//-1)

      assert_receive {:sidecar_request, %{"start_block" => 61, "end_block" => 70}}
    end

    test "passes an ascending range through unchanged" do
      stub_sidecar(Enum.map(61..70, &entry/1))

      assert {:ok, _range_data} = Firehose.fetch_range(61..70)

      assert_receive {:sidecar_request, %{"start_block" => 61, "end_block" => 70}}
    end

    test "returns native balances already valued, so eth_getBalance is never issued for them" do
      stub_sidecar([entry(64)])

      assert {:ok, %{coin_balances: coin_balances}} = Firehose.fetch_range(64..64)

      assert [from_balance, forwarder_balance] =
               Enum.sort_by(coin_balances, & &1.address_hash)
               |> Enum.sort_by(&(&1.address_hash != @from))

      assert from_balance.address_hash == @from
      assert from_balance.block_number == 64
      assert from_balance.value == 0x2E85D789C5E1B

      # a zero balance is still a known balance, not a missing one
      assert forwarder_balance.value == 0

      # value_fetched_at is what keeps CoinBalance.stream_unfetched_balances/3 from re-fetching
      assert Enum.all?(coin_balances, &match?(%DateTime{}, &1.value_fetched_at))
    end

    test "omits coin balances when the sidecar reports none" do
      stub_sidecar([Map.delete(entry(64), "balanceChanges")])

      assert {:ok, %{coin_balances: []}} = Firehose.fetch_range(64..64)
    end

    test "reports a block the sidecar could not produce as an error rather than dropping it" do
      stub_sidecar([%{"number" => 64, "block" => nil, "receipts" => [], "traces" => []}])

      assert {:ok, %{blocks: %Blocks{blocks_params: [], errors: [error]}}} = Firehose.fetch_range(64..64)
      assert %{code: 404, data: %{number: 64}} = error
    end

    test "rejects a partial range so omitted blocks stay in missing_block_ranges" do
      stub_sidecar([entry(64)])

      assert {:error, {:firehose_range_mismatch, %{missing: [65], duplicates: [], unexpected: []}}} =
               Firehose.fetch_range(64..65)
    end

    test "rejects duplicate and out-of-range block entries" do
      stub_sidecar([entry(63), entry(64), entry(64)])

      assert {:error, {:firehose_range_mismatch, %{missing: [], duplicates: [64], unexpected: [63]}}} =
               Firehose.fetch_range(64..64)
    end

    test "rejects a block whose receipts do not cover every transaction" do
      stub_sidecar([put_in(entry(64), ["receipts"], [])])

      assert {:error, {:firehose_invalid_entry, 64, :receipt_transaction_mismatch}} =
               Firehose.fetch_range(64..64)
    end

    test "rejects a block whose traces do not cover every transaction" do
      stub_sidecar([put_in(entry(64), ["traces"], [])])

      assert {:error, {:firehose_invalid_entry, 64, :trace_transaction_mismatch}} =
               Firehose.fetch_range(64..64)
    end

    test "returns an error tuple when the sidecar answers with a non-200" do
      stub_sidecar([entry(64)], 503)

      assert {:error, {:firehose_http_error, 503, _body}} = Firehose.fetch_range(64..64)
    end

    test "returns an error tuple when the body is not shaped as expected" do
      test = self()

      expect(Explorer.Mock.TeslaAdapter, :call, fn %Tesla.Env{} = env, _opts ->
        send(test, :called)
        {:ok, %{env | status: 200, body: Jason.encode!(%{"unexpected" => true})}}
      end)

      assert {:error, {:firehose_unexpected_response, _}} = Firehose.fetch_range(64..64)
    end
  end

  describe "configured?/0" do
    test "is true when a url is set" do
      assert Firehose.configured?()
    end

    test "is false when no url is set" do
      Application.put_env(:ethereum_jsonrpc, Firehose, url: nil)
      refute Firehose.configured?()
    end
  end
end
