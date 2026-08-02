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
[firehose-parity.md](firehose-parity.md). It is CPU-bound and scales by forking workers.

## Configuration

| Variable | Meaning |
|---|---|
| `INDEXER_FIREHOSE_URL` | Connector endpoint. Unset = stock JSON-RPC behaviour. |
| `INDEXER_FIREHOSE_TIMEOUT` | Request timeout, default `60s`. Raise for large ranges. |

Connector-side:

| Variable | Meaning |
|---|---|
| `FIREHOSE_ENDPOINT` | `host:port` of the Firehose gRPC endpoint |
| `FIREHOSE_API_KEY` | Sent as the `x-api-key` metadata header |
| `FIREHOSE_WORKERS` | Worker processes; defaults to `cores - 2` |
| `PORT` | HTTP listen port, default `8081` |
| `FIREHOSE_PLAINTEXT` | `true` for a non-TLS endpoint |

## Scope and limits

**Backfill only.** Realtime keeps following the chain head over JSON-RPC, where Blockscout's reorg
detection lives. That is deliberate — it is the riskiest part of an explorer and the part least
worth destabilising.

**Blockscout still needs an archive node.** Firehose carries state *changes*, not arbitrary state
*queries*. Token metadata (`name`/`symbol`/`decimals`), `balanceOf`, and contract reads all go
through `eth_call`, which Firehose cannot answer. This change replaces the history workload, not
the node.

**Pending transactions** are not in Firehose, since they are not in blocks.

## Files

| Path | |
|---|---|
| `apps/ethereum_jsonrpc/lib/ethereum_jsonrpc/firehose.ex` | connector client + response decoding |
| `apps/indexer/lib/indexer/block/fetcher.ex` | the `:source` seam |
| `apps/indexer/lib/indexer/block/catchup/fetcher.ex` | skips the async trace pass when traces arrive inline |
| `dev/firehose/firehose-sidecar.js` | the connector |
| `dev/firehose/rpc-sidecar.js` | RPC-backed test double, for running without a Firehose endpoint |
| `dev/firehose/proto/` | schemas, synced from the Buf Schema Registry |

See [firehose-block-mapping.md](firehose-block-mapping.md) for the field-by-field translation and
[firehose-parity.md](firehose-parity.md) for how 1:1 parity with RPC is verified.
