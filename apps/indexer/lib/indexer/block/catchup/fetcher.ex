# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Indexer.Block.Catchup.Fetcher do
  @moduledoc """
  Fetches and indexes block ranges from the block before the latest block to genesis (0) that are missing.
  """

  use Spandex.Decorators

  require Logger

  import Indexer.Block.Fetcher,
    only: [
      async_import_blobs: 2,
      async_import_block_rewards: 2,
      async_import_celo_epoch_block_operations: 2,
      async_import_celo_accounts: 2,
      async_import_coin_balances: 1,
      async_import_created_contract_codes: 2,
      async_import_filecoin_addresses_info: 2,
      async_import_internal_transactions: 2,
      async_import_replaced_transactions: 2,
      async_import_signed_authorizations_statuses: 2,
      async_import_token_balances: 2,
      async_import_current_token_balances: 2,
      async_import_token_instances: 1,
      async_import_tokens: 2,
      async_import_uncles: 2,
      fetch_and_import_range: 2
    ]

  alias Ecto.Changeset
  alias EthereumJSONRPC.Utility.RangesHelper
  alias Explorer.Chain
  alias Explorer.Chain.NullRoundHeight
  alias Explorer.Utility.{MassiveBlock, MissingBlockRange}
  alias Indexer.{Block, Tracer}
  alias Indexer.Block.Catchup.TaskSupervisor
  alias Indexer.Fetcher.OnDemand.ContractCreator, as: ContractCreatorOnDemand
  alias Indexer.Prometheus

  @behaviour Block.Fetcher

  defstruct block_fetcher: nil,
            memory_monitor: nil

  @doc """
  Required named arguments

    * `:json_rpc_named_arguments` - `t:EthereumJSONRPC.json_rpc_named_arguments/0` passed to
        `EthereumJSONRPC.json_rpc/2`.
  """
  def task(state) do
    Logger.metadata(fetcher: :block_catchup)
    Process.flag(:trap_exit, true)

    case get_missing_ranges_batch() do
      {[], _claim_id} ->
        %{
          first_block_number: nil,
          last_block_number: nil,
          missing_block_count: 0,
          shrunk: false
        }

      {missing_ranges, claim_id} ->
        first.._//_ = List.first(missing_ranges)
        _..last//_ = List.last(missing_ranges)

        Logger.metadata(first_block_number: first, last_block_number: last)

        missing_block_count =
          missing_ranges
          |> Stream.map(&Enum.count/1)
          |> Enum.sum()

        try do
          stream_fetch_and_import(state, missing_ranges, claim_id)
        after
          maybe_release_claim(claim_id)
        end

        %{
          first_block_number: first,
          last_block_number: last,
          missing_block_count: missing_block_count,
          shrunk: false
        }
    end
  end

  @doc """
  The number of blocks to request in one call to the JSONRPC.  Defaults to
  10.  Block requests also include the transactions for those blocks.  *These transactions
  are not paginated.
  """
  def blocks_batch_size do
    Application.get_env(:indexer, __MODULE__)[:batch_size]
  end

  @doc """
  The number of concurrent requests of `blocks_batch_size` to allow against the JSONRPC.
  Defaults to 10.  So, up to `blocks_concurrency * block_batch_size` (defaults to
  `10 * 10`) blocks can be requested from the JSONRPC at once over all
  connections.  Up to `block_concurrency * receipts_batch_size * receipts_concurrency` (defaults to
  `#{10 * Block.Fetcher.default_receipts_batch_size() * Block.Fetcher.default_receipts_concurrency()}`
  ) receipts can be requested from the JSONRPC at once over all connections.
  """
  def blocks_concurrency do
    Application.get_env(:indexer, __MODULE__)[:concurrency]
  end

  defp get_missing_ranges_batch do
    size = blocks_batch_size() * blocks_concurrency()

    if range_claiming_enabled?() do
      case MissingBlockRange.claim_latest_batch(size, range_claim_lease_duration()) do
        {:ok, %{id: claim_id, ranges: ranges}} -> {ranges, claim_id}
        {:error, reason} -> raise "failed to claim missing block ranges: #{inspect(reason)}"
      end
    else
      {MissingBlockRange.get_latest_batch(size), nil}
    end
  end

  defp range_claiming_enabled? do
    Application.get_env(:indexer, __MODULE__)
    |> Keyword.get(:range_claiming_enabled?, false)
  end

  defp range_claim_lease_duration do
    :indexer
    |> Application.get_env(__MODULE__)
    |> Keyword.get(:range_claim_lease_duration, :timer.minutes(10))
    |> max(:timer.seconds(3))
  end

  @async_import_remaining_block_data_options ~w(address_hash_to_fetched_balance_block_number)a

  @impl Block.Fetcher
  def import(_block_fetcher, options) when is_map(options) do
    {async_import_remaining_block_data_options, options_with_block_rewards_errors} =
      Map.split(options, @async_import_remaining_block_data_options)

    {block_reward_errors, options_without_block_rewards_errors} =
      pop_in(options_with_block_rewards_errors[:block_rewards][:errors])

    full_chain_import_options =
      options_without_block_rewards_errors
      |> put_in([:blocks, :params, Access.all(), :consensus], true)
      |> put_in([:blocks, :params, Access.all(), :refetch_needed], false)

    with {:import, {:ok, imported} = ok} <- {:import, Chain.import(full_chain_import_options)} do
      async_import_remaining_block_data(
        imported,
        async_import_remaining_block_data_options
        |> Map.put(:block_rewards, %{errors: block_reward_errors})
        |> Map.put(:internal_transactions_imported?, Map.has_key?(options, :internal_transactions))
      )

      ContractCreatorOnDemand.async_update_cache_of_contract_creator_on_demand(imported)

      ok
    end
  end

  defp async_import_remaining_block_data(
         imported,
         %{block_rewards: %{errors: block_reward_errors}} = options
       ) do
    realtime? = false

    async_import_block_rewards(block_reward_errors, realtime?)
    async_import_coin_balances(imported)
    async_import_created_contract_codes(imported, realtime?)
    maybe_async_import_internal_transactions(imported, options, realtime?)
    async_import_tokens(imported, realtime?)
    async_import_token_balances(imported, realtime?)
    async_import_current_token_balances(imported, realtime?)
    async_import_uncles(imported, realtime?)
    async_import_replaced_transactions(imported, realtime?)
    async_import_token_instances(imported)
    async_import_blobs(imported, realtime?)
    async_import_celo_epoch_block_operations(imported, realtime?)
    async_import_celo_accounts(imported, realtime?)
    async_import_filecoin_addresses_info(imported, realtime?)
    async_import_signed_authorizations_statuses(imported, realtime?)
  end

  # When the block source supplied traces, they were imported in the same transaction that created
  # the pending block operations, so the queue is already drained and there is nothing left to
  # trace. Queueing anyway would send the whole range back to the node's tracer and undo the point
  # of sourcing the traces in the first place.
  defp maybe_async_import_internal_transactions(_imported, %{internal_transactions_imported?: true}, _realtime?),
    do: :ok

  defp maybe_async_import_internal_transactions(imported, _options, realtime?),
    do: async_import_internal_transactions(imported, realtime?)

  defp stream_fetch_and_import(state, ranges, claim_id) do
    with_claim_renewal(claim_id, fn ->
      TaskSupervisor
      |> Task.Supervisor.async_stream(
        RangesHelper.split(ranges, blocks_batch_size()),
        &fetch_and_import_missing_range(state, &1, claim_id),
        max_concurrency: blocks_concurrency(),
        timeout: :infinity,
        shutdown: Application.get_env(:indexer, :graceful_shutdown_period)
      )
      |> handle_fetch_and_import_results(claim_id)
    end)
  end

  # Run at state.blocks_concurrency max_concurrency when called by `stream_import/1`
  @decorate trace(
              name: "fetch",
              resource: "Indexer.Block.Catchup.Fetcher.fetch_and_import_missing_range/3",
              tracer: Tracer
            )
  defp fetch_and_import_missing_range(
         %__MODULE__{block_fetcher: %Block.Fetcher{} = block_fetcher},
         first..last//_ = range,
         claim_id
       ) do
    Logger.metadata(fetcher: :block_catchup, first_block_number: first, last_block_number: last)
    Process.flag(:trap_exit, true)

    {fetch_duration, result} = :timer.tc(fn -> fetch_and_import_range(block_fetcher, range) end)

    Prometheus.Instrumenter.set_block_full_process(fetch_duration, __MODULE__)

    case result do
      {:ok, %{errors: errors}} ->
        valid_errors = handle_null_rounds(errors)
        log_errors(valid_errors, range)

        {:ok, %{range: range, errors: valid_errors}}

      {:error, {:import = step, [%Changeset{} | _] = changesets}} = error ->
        Prometheus.Instrumenter.set_import_errors_count()
        Logger.error(fn -> ["failed to validate: ", inspect(changesets), ". Retrying."] end, step: step)

        tagged_error(error, range, false)

      {:error, {:import = step, reason}} = error ->
        Prometheus.Instrumenter.set_import_errors_count()
        Logger.error(fn -> [inspect(reason), ". Retrying."] end, step: step)
        massive? = reason == :timeout
        if massive?, do: maybe_add_range_to_massive_blocks(range, claim_id)

        tagged_error(error, range, massive?)

      {:error, {step, reason}} = error ->
        Logger.error(
          fn ->
            ["failed to fetch: ", inspect(reason), ". Retrying."]
          end,
          step: step
        )

        tagged_error(error, range, false)

      {:error, {step, failed_value, _changes_so_far}} = error ->
        Logger.error(
          fn ->
            ["failed to insert: ", inspect(failed_value), ". Retrying."]
          end,
          step: step
        )

        tagged_error(error, range, false)
    end
  rescue
    exception ->
      massive? = timeout_exception?(exception)
      if massive?, do: maybe_add_range_to_massive_blocks(range, claim_id)
      Logger.error(fn -> [Exception.format(:error, exception, __STACKTRACE__), ?\n, ?\n, "Retrying."] end)
      tagged_error({:error, exception}, range, massive?)
  end

  defp handle_fetch_and_import_results(results, claim_id) do
    results
    |> Enum.reduce({[], []}, fn
      {:ok, {:ok, %{range: range, errors: errors}}}, {successful_numbers, massive_numbers} ->
        range_successful_numbers = Enum.to_list(range) -- Enum.map(errors, &block_error_to_number/1)
        {range_successful_numbers ++ successful_numbers, massive_numbers}

      {:ok, {:error, %{massive?: true, range: range}}}, {success_numbers, massive_numbers} ->
        {success_numbers, Enum.to_list(range) ++ massive_numbers}

      _result, acc ->
        acc
    end)
    |> settle_fetch_and_import_results(claim_id)
  end

  defp settle_fetch_and_import_results({successful_numbers, _massive_numbers}, nil) do
    successful_numbers
    |> numbers_to_ranges()
    |> MissingBlockRange.clear_batch()
  end

  defp settle_fetch_and_import_results({successful_numbers, massive_numbers}, claim_id) do
    completed_numbers = successful_numbers ++ massive_numbers

    case MissingBlockRange.complete_claim(claim_id, completed_numbers) do
      {:ok, owned_completed_numbers} ->
        owned_completed_numbers
        |> Enum.filter(&(&1 in massive_numbers))
        |> MassiveBlock.insert_block_numbers()

      {:error, reason} ->
        raise "failed to complete missing block range claim: #{inspect(reason)}"
    end
  end

  defp tagged_error(error, range, massive?) do
    {:error, %{error: error, massive?: massive?, range: range}}
  end

  defp maybe_add_range_to_massive_blocks(range, nil), do: add_range_to_massive_blocks(range)
  defp maybe_add_range_to_massive_blocks(_range, _claim_id), do: :ok

  defp maybe_release_claim(nil), do: :ok

  defp maybe_release_claim(claim_id) do
    case MissingBlockRange.release_claim(claim_id) do
      {:ok, _released_numbers} -> :ok
      {:error, reason} -> Logger.error("Failed to release missing block range claim: #{inspect(reason)}")
    end
  end

  defp with_claim_renewal(nil, function), do: function.()

  defp with_claim_renewal(claim_id, function) do
    parent = self()
    stop_ref = make_ref()
    lease_duration = range_claim_lease_duration()

    renewal_pid =
      spawn(fn ->
        parent_ref = Process.monitor(parent)
        renew_claim_loop(parent_ref, stop_ref, claim_id, lease_duration)
      end)

    try do
      function.()
    after
      send(renewal_pid, {:stop, stop_ref})
    end
  end

  defp renew_claim_loop(parent_ref, stop_ref, claim_id, lease_duration) do
    receive do
      {:stop, ^stop_ref} ->
        :ok

      {:DOWN, ^parent_ref, :process, _pid, _reason} ->
        :ok
    after
      div(lease_duration, 3) ->
        case MissingBlockRange.renew_claim(claim_id, lease_duration) do
          {0, nil} ->
            Logger.warning("Missing block range claim lease was lost before catchup completed")

          {_renewed_count, nil} ->
            renew_claim_loop(parent_ref, stop_ref, claim_id, lease_duration)
        end
    end
  rescue
    exception ->
      Logger.error("Failed to renew missing block range claim: #{Exception.message(exception)}")
      renew_claim_loop(parent_ref, stop_ref, claim_id, lease_duration)
  end

  defp handle_null_rounds(errors) do
    {null_rounds, other_errors} =
      Enum.split_with(errors, fn
        %{message: "requested epoch was a null round"} -> true
        _ -> false
      end)

    null_rounds
    |> Enum.map(&block_error_to_number/1)
    |> NullRoundHeight.insert_heights()

    other_errors
  end

  defp log_errors([], _range), do: :ok

  defp log_errors(errors, range),
    do: Logger.error(fn -> "Failed to fetch block range #{inspect(range)}: #{inspect(errors)}" end)

  defp timeout_exception?(%{message: message}) when is_binary(message) do
    match_timeout_exception?(message)
  end

  defp timeout_exception?(%{postgres: %{message: message}}) when is_binary(message) do
    match_timeout_exception?(message)
  end

  defp timeout_exception?(_exception), do: false

  defp match_timeout_exception?(error_message) do
    String.match?(error_message, ~r/due to a timeout/) or String.match?(error_message, ~r/due to user request/) or
      String.match?(error_message, ~r/ssl recv: closed/)
  end

  @doc """
  Adds block numbers or block numbers range into `massive_blocks` and clears them from `missing_block_ranges`
  """
  @spec add_range_to_massive_blocks(Range.t() | [non_neg_integer()]) :: any()
  def add_range_to_massive_blocks([]), do: :ok

  def add_range_to_massive_blocks(range) do
    clear_missing_ranges(range)

    range
    |> Enum.to_list()
    |> MassiveBlock.insert_block_numbers()
  end

  defp clear_missing_ranges(initial_range, errors \\ []) do
    success_numbers = Enum.to_list(initial_range) -- Enum.map(errors, &block_error_to_number/1)

    success_numbers
    |> numbers_to_ranges()
    |> MissingBlockRange.clear_batch()
  end

  defp block_error_to_number(%{data: %{number: number}}) when is_integer(number), do: number

  defp numbers_to_ranges([]), do: []

  defp numbers_to_ranges(numbers) when is_list(numbers) do
    numbers
    |> Enum.sort(&>=/2)
    |> Enum.chunk_while(
      nil,
      fn
        number, nil ->
          {:cont, number..number}

        number, first..last//_ when number == last - 1 ->
          {:cont, first..number}

        number, range ->
          {:cont, range, number..number}
      end,
      fn range -> {:cont, range, nil} end
    )
  end
end
