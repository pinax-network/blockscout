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

Connector-side — see [`dev/firehose/.env.example`](../dev/firehose/.env.example). A `.env` file
next to the connector is read automatically; real environment variables take precedence.

| Variable | Meaning |
|---|---|
| `FIREHOSE_ENDPOINT` | `host:port` of the Firehose gRPC endpoint |
| `FIREHOSE_API_KEY` | Long-lived key, sent as `x-api-key`. Pinax / StreamingFast hosted endpoints. |
| `FIREHOSE_BEARER_TOKEN` | Short-lived JWT, sent as `authorization: bearer <token>`. Deployments behind StreamingFast's auth service. |
| `FIREHOSE_WORKERS` | Worker processes; defaults to `cores - 2` |
| `PORT` | HTTP listen port, default `8081` |
| `FIREHOSE_PLAINTEXT` | `true` for a non-TLS endpoint |

**Firehose endpoints require authentication.** Set exactly one of `FIREHOSE_API_KEY` or
`FIREHOSE_BEARER_TOKEN` — whichever your provider issues. The connector warns at startup if
neither is present, and `GET /health` reports which mode is active:

```json
{"ok": true, "endpoint": "...", "source": "firehose", "auth": "api-key"}
```

## Scope and limits

**Backfill only.** Realtime keeps following the chain head over JSON-RPC, where Blockscout's reorg
detection lives. That is deliberate — it is the riskiest part of an explorer and the part least
worth destabilising.

**Native balances are served from Firehose too.** `balance_changes` is recorded post-state, so
coin balances arrive already valued and `Indexer.Fetcher.CoinBalance` never issues `eth_getBalance`
for them. Verified end to end: 300 of 300 balances in Blockscout's own database match
`eth_getBalance` at the same block exactly.

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
