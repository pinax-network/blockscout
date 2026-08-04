# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.SmartContract.SolcDownloader do
  @moduledoc """
  Checks to see if the requested solc compiler version exists, and if not it
  downloads and stores the file.
  """
  use GenServer

  alias Explorer.HttpClient
  alias Explorer.SmartContract.CompilerVersion

  @latest_compiler_refetch_time :timer.minutes(30)
  @compiler_versions_refetch_time :timer.minutes(30)

  def ensure_exists(version) do
    path = file_path(version)

    if File.exists?(path) && version !== "latest" do
      path
    else
      GenServer.call(__MODULE__, {:ensure_exists, version}, 60_000)
    end
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  # sobelow_skip ["Traversal"]
  @impl true
  def init([]) do
    File.mkdir(compiler_dir())

    {:ok, %{compiler_versions: nil, compiler_versions_fetched_at: nil}}
  end

  @impl true
  def handle_call({:ensure_exists, version}, _from, state) do
    case compiler_versions(state) do
      {:ok, compiler_versions, state} ->
        {:reply, ensure_compiler_file(version, compiler_versions), state}

      {:error, _reason} ->
        {:reply, false, state}
    end
  end

  defp ensure_compiler_file(version, compiler_versions) do
    if version in compiler_versions do
      path = file_path(version)

      maybe_download_compiler(version, path)

      path
    else
      false
    end
  end

  # sobelow_skip ["Traversal"]
  defp maybe_download_compiler(version, path) do
    if fetch?(version, path) do
      temp_path = file_path("#{version}-tmp")

      contents = download(version)

      file = File.open!(temp_path, [:write, :exclusive])

      IO.binwrite(file, contents)

      File.rename(temp_path, path)
    end
  end

  defp compiler_versions(
         %{
           compiler_versions: compiler_versions,
           compiler_versions_fetched_at: compiler_versions_fetched_at
         } = state
       )
       when is_list(compiler_versions) and is_integer(compiler_versions_fetched_at) do
    elapsed_time = System.monotonic_time(:millisecond) - compiler_versions_fetched_at

    if elapsed_time < @compiler_versions_refetch_time do
      {:ok, compiler_versions, state}
    else
      fetch_compiler_versions(state)
    end
  end

  defp compiler_versions(state), do: fetch_compiler_versions(state)

  defp fetch_compiler_versions(state) do
    case CompilerVersion.fetch_versions(:solc) do
      {:ok, compiler_versions} ->
        state = %{
          state
          | compiler_versions: compiler_versions,
            compiler_versions_fetched_at: System.monotonic_time(:millisecond)
        }

        {:ok, compiler_versions, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch?("latest", path) do
    case File.stat(path) do
      {:error, :enoent} ->
        true

      {:ok, %{mtime: mtime}} ->
        last_modified = NaiveDateTime.from_erl!(mtime)
        diff = Timex.diff(NaiveDateTime.utc_now(), last_modified, :milliseconds)

        diff > @latest_compiler_refetch_time
    end
  end

  defp fetch?(_, path) do
    not File.exists?(path)
  end

  defp file_path(version) do
    Path.join(compiler_dir(), "#{version}.js")
  end

  defp compiler_dir do
    Application.app_dir(:explorer, "priv/solc_compilers/")
  end

  defp download(version) do
    download_path = "https://binaries.soliditylang.org/bin/soljson-#{version}.js"

    download_path
    |> HttpClient.get!([], timeout: 60_000, recv_timeout: 60_000)
    |> Map.get(:body)
  end
end
