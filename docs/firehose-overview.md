# Firehose-backed backfill for Blockscout

## Why

Blockscout's catchup (backfill) pipeline rebuilds each block range from three separate passes
against a JSON-RPC archive node:

1. `eth_getBlockByNumber` — the block and its transactions
2. `eth_getBlockReceipts` — receipts and logs
3. `debug_traceBlockByNumber` — execution traces, deferred through the `pending_block_operations`
   queue and issued **once per block**, long after the block itself was imported

The third pass dominates. A Firehose "extended" block already contains all three, so one stream
replaces all of it, and internal transactions can be imported in the *same database transaction*
as the blocks that own them.

This matters most on high-throughput chains. Robinhood Chain produces blocks roughly ten times a
second; re-indexing history, recovering from an outage, or standing up a new instance is where the
cost lives.

## Shape of the change

```
Blockscout (Elixir)              connector (Node)            Firehose
───────────────────              ────────────────            ────────
Indexer.Block.Catchup.Fetcher
  └─ Indexer.Block.Fetcher
       └─ :source                POST /v1/blocks
          EthereumJSONRPC.       {start_block, end_block}
          Firehose          ───> ─────────────────────> sf.firehose.v2.Stream/Blocks
                            <─── {"blocks":[{number,      (sf.ethereum.type.v2.Block,
                                  block, receipts,         "extended" detail level)
                                  traces}]}
       └─ Explorer.Chain.Import.all/1
          (blocks + receipts + logs + internal transactions, one transaction)
```

Two pieces:

- **In Blockscout** — a `:source` seam on `Indexer.Block.Fetcher`. When unset (the default),
  behaviour is byte-for-byte what it is today. When set, the fetcher gets blocks, receipts and
  traces from the source in one call and passes internal transactions straight into the import.
- **In the connector** — a standalone service that speaks Firehose gRPC upstream and plain
  HTTP/JSON downstream. Blockscout gains no gRPC or protobuf dependencies.

## Why a connector rather than gRPC in Elixir

Blockscout's umbrella has no gRPC or protobuf dependency anywhere — every microservice interface
is HTTP/JSON. Adding `grpc` + `protobuf` plus generated `sf.ethereum.type.v2` bindings is a heavy
dependency addition for an upstream project to accept, and a maintenance burden.

The trade is JSON transcoding cost, which is real and is the connector's throughput ceiling — see
[firehose-parity.md](firehose-parity.md). It is CPU-bound, so the connector uses eight workers.

## Configuration

Only two Firehose-specific variables are required. Pass them to the Blockscout indexer and its
co-located connector:

| Variable | Meaning |
|---|---|
| `FIREHOSE_ENDPOINT` | TLS Firehose gRPC endpoint in `host:port` form; setting it enables Firehose catchup. |
| `FIREHOSE_API_KEY` | API key sent as `x-api-key` metadata. |

The internal settings are fixed: the connector listens on `127.0.0.1:8082`, uses TLS upstream,
runs eight workers, and Blockscout waits up to 60 seconds per range. Chain mapping reuses the
native `CHAIN_TYPE` setting instead of adding a Firehose-specific selector. The connector fails at
startup if the endpoint or API key is missing. `GET /health` reports the active chain family:

```json
{"ok": true, "endpoint": "...", "source": "firehose", "chainFamily": "arbitrum", "auth": "api-key"}
```

### Scaling catchup

One Blockscout indexer already runs catchup ranges concurrently. The main controls are:

| Variable | Effect |
|---|---|
| `INDEXER_CATCHUP_BLOCKS_CONCURRENCY` | Concurrent range requests from Blockscout; default `10` |
| `INDEXER_CATCHUP_BLOCKS_BATCH_SIZE` | Blocks per range request; default `10` |

Run one catchup-enabled Blockscout indexer. Raise its native batch size and concurrency gradually
until the fixed connector pool, Firehose upstream, or database becomes the bottleneck. Larger
batches amortise stream setup, but also increase memory and response size.

Do not scale catchup by starting several indexer replicas against the same database. The current
`missing_block_ranges` reader does not claim or lease work: each replica can select the same newest
ranges, producing duplicate Firehose streams and duplicate import attempts rather than useful
horizontal speedup. True multi-instance backfill needs an atomic range-claim mechanism.

## Scope and limits

### Chain-family support

| Family | Status | Notes |
|---|---|---|
| Arbitrum Orbit | Supported with a known fee-cap source gap | Selected by native `CHAIN_TYPE=arbitrum`; system calls attach to the explicit ArbOS internal transaction type. Robinhood Firehose currently omits type-2 maximum fee fields, so the connector preserves effective `gasPrice` and leaves those unavailable fields absent ([issue #4](https://github.com/pinax-network/blockscout/issues/4)). |
| Ethereum Cancun/Prague | Experimental | Native `CHAIN_TYPE=ethereum` and the default build select this mapping. Header, blob receipt/transaction and EIP-7702 mappings are fixture-tested; production database parity is still required before declaring a deployment certified. |
| Optimism | Unsupported | Deposit enum is recognized but the protobuf lacks the full node-specific deposit payload. The connector fails closed. |
| Polygon | Unsupported | State-sync enum is recognized but database and trace-placement parity are unverified. The connector fails closed. |

Unknown transaction types and mismatched family-specific types fail the entire requested range;
they are never imported as legacy transactions.

**Backfill only.** Realtime keeps following the chain head over JSON-RPC, where Blockscout's reorg
detection lives. That is deliberate — it is the riskiest part of an explorer and the part least
worth destabilising.

**Native balances are served from Firehose too.** `balance_changes` is recorded post-state, so
coin balances arrive already valued and `Indexer.Fetcher.CoinBalance` never issues `eth_getBalance`
for them. The connector excludes reverted-call changes and, for failed transactions, keeps only
the root gas/fee changes that the Firehose schema defines as persistent. Verified end to end: 300
of 300 balances in Blockscout's own database match `eth_getBalance` at the same block exactly.

**Blockscout still needs node access** for token balances and token/NFT metadata, which go through
`eth_call`.

How much of that residual is *inherently* node-only is a smaller set than it first appears.
Extended blocks carry `balance_changes`, `code_changes`, `nonce_changes`, `storage_changes` and
`keccak_preimages`, which between them cover native balances, contract code, nonces, and — via
storage keys resolved through their keccak preimages — ERC-20 `balanceOf`. Only token and NFT
metadata genuinely require `eth_call`, and that is one-time per token rather than per block.
Measured in [firehose-node-dependency.md](firehose-node-dependency.md). `balanceOf` derivation is
deliberately **not** implemented: it reaches only 94.2% and the failures are undetectable from
block data, so it falls back to `eth_call` rather than risk a wrong balance.

**Pending transactions** are not in Firehose, since they are not in blocks.

## Files

| Path | |
|---|---|
| `apps/ethereum_jsonrpc/lib/ethereum_jsonrpc/firehose.ex` | connector client + response decoding |
| `apps/indexer/lib/indexer/block/fetcher.ex` | the `:source` seam |
| `apps/indexer/lib/indexer/block/catchup/fetcher.ex` | skips the async trace pass when traces arrive inline |
| `dev/firehose/analyze-coverage.js`, `derive-gated.js` | measurement tools behind the node-dependency analysis |
| `dev/firehose/firehose-sidecar.js` | the connector |
| `dev/firehose/rpc-sidecar.js` | RPC-backed test double, for running without a Firehose endpoint |
| `dev/firehose/proto/` | schemas, synced from the Buf Schema Registry |

See [firehose-block-mapping.md](firehose-block-mapping.md) for the field-by-field translation,
[firehose-parity.md](firehose-parity.md) for how 1:1 parity with RPC is verified, and
[firehose-node-dependency.md](firehose-node-dependency.md) for what still needs a node and how much
of it an extended block could absorb.
