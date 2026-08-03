# Firehose-backed backfill — local setup

> Design, field mapping and parity results live in [`docs/firehose-overview.md`](../../docs/firehose-overview.md),
> [`docs/firehose-block-mapping.md`](../../docs/firehose-block-mapping.md) and
> [`docs/firehose-parity.md`](../../docs/firehose-parity.md). This file is just how to run it locally.

Blockscout's catchup (backfill) pipeline normally rebuilds each block range from three passes
against a JSON-RPC node: `eth_getBlockByNumber`, `eth_getBlockReceipts`, and a deferred
`debug_traceBlockByNumber` per block driven off `pending_block_operations`. With
`FIREHOSE_ENDPOINT` set, catchup instead gets blocks, receipts, logs and call traces from a
co-located Firehose sidecar in one request per range, and imports the internal transactions in the
same database transaction as the blocks.

Realtime is unaffected — it keeps following the head over JSON-RPC, where its reorg detection lives.

## Configuration

Only two Firehose-specific variables are required:

| Variable | Meaning |
|---|---|
| `FIREHOSE_ENDPOINT` | TLS Firehose gRPC endpoint in `host:port` form; setting it enables Firehose catchup. |
| `FIREHOSE_API_KEY` | API key sent as `x-api-key` metadata. |

The connector is fixed at eight workers on `127.0.0.1:8082`, and Blockscout uses a 60-second
request timeout. Chain mapping reuses Blockscout's native `CHAIN_TYPE`: `arbitrum` uses the verified
Orbit policy, while `ethereum` and the default build use the experimental Cancun/Prague mapping.
Optimism and Polygon fail closed because their end-to-end database parity is not certified and the
protobuf lacks the complete Optimism deposit payload.

## Sidecar contract

`EthereumJSONRPC.Firehose` posts

```json
{"start_block": 61, "end_block": 70}
```

and expects `200` with

```json
{"blocks": [{"number": 61, "block": {...}, "receipts": [...], "traces": [...]}]}
```

`block`, `receipts` and `traces` are the **verbatim** results of `eth_getBlockByNumber` (with full
transaction objects), `eth_getBlockReceipts`, and `debug_traceBlockByNumber` with `callTracer`.
Keeping them verbatim means the payload goes through the same parsers as node responses, so
Firehose-sourced and node-sourced data cannot drift apart.

Requirements:

- `number` is always present, even when `block` is `null`, so a block the sidecar could not produce
  is reported against the right block number.
- `receipts` must contain a receipt for every transaction in `block` —
  `Indexer.Block.Fetcher.Receipts.put/2` looks them up with `Map.fetch!/2`.
- Ranges are requested ascending; the catchup fetcher's descending ranges are normalized first.

See the moduledoc in `apps/ethereum_jsonrpc/lib/ethereum_jsonrpc/firehose.ex` for the authoritative
version.

## Files here

- `firehose-sidecar.js` — **the real one.** Streams `sf.ethereum.type.v2.Block` over gRPC via
  `sf.firehose.v2.Stream/Blocks` and reshapes each block into the three payloads.
- `rpc-sidecar.js` — a test double backed by a plain JSON-RPC node, for exercising the Blockscout
  side without a Firehose endpoint.
- `proto/` — `sf/firehose/v2/firehose.proto` and `sf/ethereum/type/v2/type.proto`. Note these come
  from **two different Buf modules**: `streamingfast/firehose` (the Stream service) and
  `streamingfast/firehose-ethereum` (the block type). `Response.block` is a `google.protobuf.Any`
  that must be unpacked against the latter.
- `local-env.sh` — environment for a local indexer-only run.
- `verify.sql` — row counts, internal transactions, and a fingerprint of the indexed data for
  comparing a Firehose run against a stock JSON-RPC run.

## Running against a Firehose endpoint

```bash
cd dev/firehose && npm ci
export FIREHOSE_ENDPOINT="<host>:443"
export FIREHOSE_API_KEY="<key>"
node firehose-sidecar.js
```

Run one catchup-enabled Blockscout indexer. Scale it with Blockscout's native
`INDEXER_CATCHUP_BLOCKS_BATCH_SIZE` and `INDEXER_CATCHUP_BLOCKS_CONCURRENCY`; both default to `10`.
Increase them gradually until the fixed eight-worker connector, Firehose upstream, or database
becomes the bottleneck. Multiple catchup-enabled indexers sharing one database are not supported.

Or pass them inline:

```bash
FIREHOSE_ENDPOINT="<host>:443" FIREHOSE_API_KEY="<key>" node firehose-sidecar.js
```

`GET /health` reports the selected native chain family and API-key authentication. `.env` is
gitignored; never commit a key.

## Known fidelity gaps vs a node's callTracer

- **CREATE2 is indistinguishable from CREATE.** `sf.ethereum.type.v2.CallType` has no `CREATE2`
  member, so a create2 internal transaction is recorded as `:create` rather than `:create2`.
  Recovering it would mean inferring from `Call.keccak_preimages`.
- **`eth_call` is not covered.** Firehose carries storage changes, not arbitrary state queries, so
  token metadata (`name`/`symbol`/`decimals`), `balanceOf`, and contract reads still need an
  archive RPC. This does not affect the block/receipt/trace backfill path, but it means Blockscout
  still needs a node for its on-demand and token fetchers.
- **Pending transactions** are not in Firehose, since they are not in blocks.

## Full trace parity check

The parity command compares every call frame by transaction and derived trace address, including
`type`, `from`, `to`, `value`, `gas`, `gasUsed`, `input`, `output`, and `error`:

```bash
RPC_URL="<archive-rpc>" START_BLOCK=25899000 END_BLOCK=25899099 npm run verify:traces
```

A frame-count match alone is not accepted as parity.

## Running the local end-to-end test

```bash
# devnet + datastores
docker run -d --name fh-anvil -p 8545:8545 ghcr.io/foundry-rs/foundry:latest \
  "anvil --host 0.0.0.0 --chain-id 31337 --block-time 2 --steps-tracing"
docker run -d --name fh-db -e POSTGRES_DB=blockscout -e POSTGRES_USER=blockscout \
  -e POSTGRES_PASSWORD=blockscout -p 7432:5432 --shm-size=256m postgres:17
docker run -d --name fh-redis -p 6379:6379 redis:7

# connector (RPC-backed test double - no real Firehose endpoint needed)
RPC_URL=http://127.0.0.1:8545 PORT=8082 node dev/firehose/rpc-sidecar.js &

# indexer
source dev/firehose/local-env.sh
export BLOCK_RANGES="1..70" FIREHOSE_ENDPOINT="rpc-test-double"
export FIREHOSE_API_KEY="local-test-only"
mix ecto.create && mix ecto.migrate
mix run --no-halt
```

Then `psql ... -f dev/firehose/verify.sql`. `pending_block_operations` should be `0` — the traces
were imported inline rather than queued for the node's tracer.

To compare against stock behaviour, truncate the chain tables, unset `FIREHOSE_ENDPOINT`, re-run,
and check the fingerprints match.
