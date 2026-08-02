# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule EthereumJSONRPC.Firehose do
  @moduledoc """
  Fetches whole block ranges - blocks, receipts, logs and call traces - from a Firehose-backed
  sidecar in a single HTTP round trip.

  A Firehose "extended" block already carries everything the indexer needs: the header, its
  transactions, their receipts and logs, and the full call tree for every transaction. The
  JSON-RPC pipeline has to rebuild that from three separate passes - `eth_getBlockByNumber`,
  `eth_getBlockReceipts`, and a `debug_traceBlockByNumber` per block deferred through
  `pending_block_operations`. This module collapses them into one request per range, which is
  where the backfill speedup comes from.

  ## Sidecar contract

  The sidecar is a separate service that consumes Firehose (gRPC stream or merged block files)
  and re-emits the data as JSON over HTTP. It receives

      POST <url>
      {"start_block": 100, "end_block": 199}

  and must answer `200` with

      {"blocks": [
        {
          "number": 100,
          "block": {...},
          "receipts": [{...}, ...],
          "traces": [{"txHash": "0x...", "result": {...}}, ...]
        },
        ...
      ]}

  The three payload fields are the **verbatim** results of the JSON-RPC calls they stand in for -
  `eth_getBlockByNumber` (with full transaction objects), `eth_getBlockReceipts`, and
  `debug_traceBlockByNumber` with `callTracer`. Keeping them verbatim is deliberate: it lets this
  module hand them to the same parsers the JSON-RPC pipeline uses, so Firehose-sourced and
  node-sourced data cannot drift apart.

  Requirements the sidecar must honour:

    * `"number"` is always present, even when `"block"` is `null` (a block the sidecar could not
      produce). It is what lets a missing block be reported against the right block number.
    * `"receipts"` must contain a receipt for *every* transaction in `"block"`.
      `Indexer.Block.Fetcher.Receipts.put/2` looks receipts up by transaction hash with
      `Map.fetch!/2` and will raise on a missing one.
    * `"blocks"` may be returned in any order and may omit blocks outside the requested range,
      but every requested block number should appear exactly once.

  ## Configuration

      config :ethereum_jsonrpc, EthereumJSONRPC.Firehose,
        url: "http://firehose-sidecar:8080/v1/blocks",
        http_options: [recv_timeout: 60_000, timeout: 60_000]
  """

  require Logger

  import EthereumJSONRPC, only: [quantity_to_integer: 1]

  alias EthereumJSONRPC.{Blocks, Geth, Logs, Receipts}
  alias Utils.HttpClient.TeslaHelper

  @typedoc """
  Everything `Indexer.Block.Fetcher` needs for one block range.

  `:receipts` and `:internal_transactions` are `nil` when the source does not provide them, which
  tells the fetcher to fall back to its own JSON-RPC passes for that data.
  """
  @type range_data :: %{
          blocks: Blocks.t(),
          receipts: %{logs: [map()], receipts: [map()]} | nil,
          internal_transactions: [map()] | nil,
          coin_balances: [map()] | nil
        }

  @doc """
  Fetches every block in `range` along with its receipts, logs and call traces.

  Returns `{:error, reason}` if the sidecar is unreachable, answers with a non-200 status, or
  returns a body that is not shaped as documented above. Callers are expected to treat that the
  same way they treat a JSON-RPC failure - the range stays in `missing_block_ranges` and is
  retried.
  """
  @spec fetch_range(Range.t()) :: {:ok, range_data()} | {:error, reason :: term()}
  def fetch_range(first..last//_ = _range) do
    # The catchup fetcher walks the chain backwards, so its ranges are descending (70..61). The
    # sidecar is asked for an ascending span either way - block order carries no meaning here,
    # `Blocks.from_responses/2` correlates by id.
    {start_block, end_block} = if first <= last, do: {first, last}, else: {last, first}

    with {:ok, entries} <- post_range(start_block, end_block),
         {:ok, internal_transactions} <- to_internal_transactions(entries) do
      {:ok,
       %{
         blocks: to_blocks(entries),
         receipts: to_receipts(entries),
         internal_transactions: internal_transactions,
         coin_balances: to_coin_balances(entries)
       }}
    end
  end

  @doc """
  Whether a Firehose sidecar URL is configured.
  """
  @spec configured?() :: boolean()
  def configured?, do: not is_nil(url())

  defp post_range(first, last) do
    body = Jason.encode!(%{start_block: first, end_block: last})
    http_options = config(:http_options) || []

    case do_post(url(), body, http_options) do
      {:ok, %Tesla.Env{status: 200, body: response_body}} ->
        decode_body(response_body)

      {:ok, %Tesla.Env{status: status, body: response_body}} ->
        {:error, {:firehose_http_error, status, truncate(response_body)}}

      {:error, reason} ->
        {:error, {:firehose_transport_error, reason}}
    end
  end

  defp do_post(nil, _body, _http_options), do: {:error, :firehose_url_not_configured}

  defp do_post(url, body, http_options) do
    Tesla.post(TeslaHelper.client(http_options), url, body,
      headers: [{"content-type", "application/json"}],
      opts: TeslaHelper.request_opts(http_options)
    )
  rescue
    error -> {:error, error}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  defp decode_body(response_body) when is_map(response_body), do: extract_entries(response_body)

  defp decode_body(response_body) do
    case Jason.decode(response_body) do
      {:ok, decoded} -> extract_entries(decoded)
      {:error, error} -> {:error, {:firehose_decode_error, error}}
    end
  end

  defp extract_entries(%{"blocks" => entries}) when is_list(entries), do: {:ok, entries}
  defp extract_entries(other), do: {:error, {:firehose_unexpected_response, truncate(other)}}

  # Rebuilds the JSON-RPC batch response `EthereumJSONRPC.Blocks.from_responses/2` expects, so the
  # Firehose payload goes through exactly the same block/transaction/withdrawal parsing as a
  # response from a node would.
  defp to_blocks(entries) do
    {responses, id_to_params} =
      entries
      |> Enum.with_index()
      |> Enum.reduce({[], %{}}, fn {entry, id}, {responses, id_to_params} ->
        {[%{id: id, result: entry["block"]} | responses],
         Map.put(id_to_params, id, %{number: entry_block_number(entry)})}
      end)

    Blocks.from_responses(responses, id_to_params)
  end

  defp to_receipts(entries) do
    elixir_receipts =
      entries
      |> Enum.flat_map(&(&1["receipts"] || []))
      |> Receipts.to_elixir()

    %{
      logs: elixir_receipts |> Receipts.elixir_to_logs() |> Logs.elixir_to_params(),
      receipts: Receipts.elixir_to_params(elixir_receipts)
    }
  end

  defp to_internal_transactions(entries) do
    {responses, id_to_params} =
      entries
      |> Enum.with_index()
      |> Enum.reduce({[], %{}}, fn {entry, id}, {responses, id_to_params} ->
        {[%{id: id, result: entry["traces"] || []} | responses],
         Map.put(id_to_params, id, entry_block_number(entry))}
      end)

    Geth.block_traces_to_internal_transactions_params(responses, id_to_params, json_rpc_named_arguments())
  end

  # Native balances are *recorded* state - the node wrote the post-state value down - so they need
  # no interpretation and land already fetched. `value_fetched_at` is what keeps
  # `CoinBalance.stream_unfetched_balances/3` from ever picking them up again.
  defp to_coin_balances(entries) do
    fetched_at = DateTime.utc_now()

    Enum.flat_map(entries, fn entry ->
      block_number = entry_block_number(entry)

      entry
      |> Map.get("balanceChanges", [])
      |> Enum.map(fn %{"address" => address, "value" => value} ->
        %{
          address_hash: address,
          block_number: block_number,
          value: quantity_to_integer(value),
          value_fetched_at: fetched_at
        }
      end)
    end)
  end

  defp entry_block_number(%{"number" => number}) when is_integer(number), do: number
  defp entry_block_number(%{"number" => number}) when is_binary(number), do: quantity_to_integer(number)
  defp entry_block_number(%{"block" => %{"number" => number}}), do: quantity_to_integer(number)

  # Only reached by the opcode/`structLogs` tracer path inside
  # `Geth.block_traces_to_internal_transactions_params/3`, which Firehose `callTracer` output does
  # not take. Passed through so that path stays correct if it ever is.
  defp json_rpc_named_arguments, do: Application.get_env(:indexer, :json_rpc_named_arguments, [])

  defp url, do: config(:url)

  defp config(key), do: Application.get_env(:ethereum_jsonrpc, __MODULE__)[key]

  defp truncate(term) do
    term |> inspect(limit: 20, printable_limit: 500) |> String.slice(0, 500)
  end
end
