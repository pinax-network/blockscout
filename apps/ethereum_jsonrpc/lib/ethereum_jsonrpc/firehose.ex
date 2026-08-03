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
    * `"traceFallback": true` asks the indexer to use its native JSON-RPC trace fetcher for the
      whole range. Blocks and receipts still use Firehose, while `pending_block_operations` keeps
      trace completion durable.
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
         :ok <- validate_entries(entries, start_block, end_block),
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

  # Catchup clears every requested number that is not represented by a `Blocks` error. If the
  # sidecar silently omits a block, accepting the partial response here would therefore remove it
  # from `missing_block_ranges` without ever importing it. The transaction-level checks are just as
  # important: importing an incomplete trace list drains the pending operation for the whole block
  # and makes the missing internal transactions permanent.
  defp validate_entries(entries, start_block, end_block) do
    with {:ok, block_numbers} <- entry_block_numbers(entries),
         :ok <- validate_block_numbers(block_numbers, start_block, end_block) do
      validate_entry_payloads(entries)
    end
  end

  defp validate_entry_payloads([]), do: :ok

  defp validate_entry_payloads([entry | entries]) do
    case validate_entry(entry) do
      :ok -> validate_entry_payloads(entries)
      {:error, _reason} = error -> error
    end
  end

  defp entry_block_numbers(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, block_numbers} ->
      case safe_entry_block_number(entry) do
        {:ok, block_number} -> {:cont, {:ok, [block_number | block_numbers]}}
        :error -> {:halt, {:error, {:firehose_invalid_entry, :missing_or_invalid_block_number}}}
      end
    end)
  end

  defp validate_block_numbers(block_numbers, start_block, end_block) do
    expected = MapSet.new(start_block..end_block)
    actual = MapSet.new(block_numbers)

    duplicates =
      block_numbers
      |> Enum.frequencies()
      |> Enum.flat_map(fn
        {block_number, count} when count > 1 -> [block_number]
        _ -> []
      end)
      |> Enum.sort()

    missing = expected |> MapSet.difference(actual) |> Enum.sort()
    unexpected = actual |> MapSet.difference(expected) |> Enum.sort()

    if missing == [] and duplicates == [] and unexpected == [] do
      :ok
    else
      {:error, {:firehose_range_mismatch, %{missing: missing, duplicates: duplicates, unexpected: unexpected}}}
    end
  end

  defp validate_entry(
         %{
           "block" => nil,
           "receipts" => [],
           "traces" => []
         } = entry
       ),
       do: validate_balance_changes(entry)

  defp validate_entry(
         %{
           "block" => %{"number" => block_number, "transactions" => transactions},
           "receipts" => receipts,
           "traces" => traces
         } = entry
       )
       when is_list(transactions) and is_list(receipts) and is_list(traces) do
    entry_number = entry_block_number(entry)

    with :ok <- validate_block_number(block_number, entry_number),
         {:ok, transaction_hashes} <- extract_hashes(transactions, "hash"),
         {:ok, receipt_hashes} <- extract_hashes(receipts, "transactionHash"),
         {:ok, trace_hashes} <- extract_hashes(traces, "txHash"),
         :ok <- validate_receipt_hashes(receipt_hashes, transaction_hashes, entry_number),
         :ok <- validate_trace_hashes(trace_hashes, transaction_hashes, entry_number) do
      validate_balance_changes(entry)
    end
  end

  defp validate_entry(entry) do
    block_number =
      case safe_entry_block_number(entry) do
        {:ok, number} -> number
        :error -> :unknown
      end

    {:error, {:firehose_invalid_entry, block_number, :invalid_payload}}
  end

  defp validate_block_number(block_number, entry_number) do
    if quantity_to_integer(block_number) == entry_number do
      :ok
    else
      {:error, {:firehose_invalid_entry, entry_number, :block_number_mismatch}}
    end
  rescue
    _error -> {:error, {:firehose_invalid_entry, entry_number, :invalid_block_number}}
  end

  defp extract_hashes(entries, key) do
    entries
    |> Enum.reduce_while({:ok, []}, fn
      %{^key => hash}, {:ok, hashes} when is_binary(hash) ->
        {:cont, {:ok, [String.downcase(hash) | hashes]}}

      _entry, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, hashes} -> {:ok, Enum.reverse(hashes)}
      :error -> {:error, {:firehose_invalid_transaction_data, key}}
    end
  end

  defp validate_receipt_hashes(receipt_hashes, transaction_hashes, block_number) do
    if Enum.sort(receipt_hashes) == Enum.sort(transaction_hashes) do
      :ok
    else
      {:error, {:firehose_invalid_entry, block_number, :receipt_transaction_mismatch}}
    end
  end

  defp validate_trace_hashes(trace_hashes, transaction_hashes, block_number) do
    # Geth's block-trace normalizer assigns transaction indexes from response order, so traces must
    # be in the same order as the block's transactions rather than merely contain the same hashes.
    if trace_hashes == transaction_hashes do
      :ok
    else
      {:error, {:firehose_invalid_entry, block_number, :trace_transaction_mismatch}}
    end
  end

  defp validate_balance_changes(entry) do
    if is_list(Map.get(entry, "balanceChanges", [])) do
      :ok
    else
      {:error, {:firehose_invalid_entry, entry_block_number(entry), :invalid_balance_changes}}
    end
  end

  defp safe_entry_block_number(entry) do
    {:ok, entry_block_number(entry)}
  rescue
    _error -> :error
  end

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
      |> Enum.flat_map(&Map.fetch!(&1, "receipts"))
      |> Receipts.to_elixir()

    %{
      logs: elixir_receipts |> Receipts.elixir_to_logs() |> Logs.elixir_to_params(),
      receipts: Receipts.elixir_to_params(elixir_receipts)
    }
  end

  defp to_internal_transactions(entries) do
    if Enum.any?(entries, &(Map.get(&1, "traceFallback", false) == true)) do
      {:ok, nil}
    else
      {responses, id_to_params} =
        entries
        |> Enum.with_index()
        |> Enum.reduce({[], %{}}, fn {entry, id}, {responses, id_to_params} ->
          {[%{id: id, result: Map.fetch!(entry, "traces")} | responses],
           Map.put(id_to_params, id, entry_block_number(entry))}
        end)

      Geth.block_traces_to_internal_transactions_params(responses, id_to_params, json_rpc_named_arguments())
    end
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
