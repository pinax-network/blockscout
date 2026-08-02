# Verifying 1:1 parity with JSON-RPC

The connector is only useful if a Firehose-sourced index is indistinguishable from a node-sourced
one. This is how that is checked, and what it currently measures.

Two levels:

1. **Frame-level** — compare the connector's `callTracer` output against a node's, frame by frame.
   Isolates the translation layer; no database involved.
2. **End-to-end** — index the same block range twice, once each way, and compare what lands in
   Postgres.

## Frame-level

For each block, pull `debug_traceBlockByNumber(callTracer)` from an archive node and the same range
from the connector, flatten both call trees to `(depth, type, from, to)` and compare as multisets.
Any surplus on the RPC side is a frame the connector is dropping.

This is what surfaced all three mapping subtleties in
[firehose-block-mapping.md](firehose-block-mapping.md). Counting only totals hides them — the
`system_calls` gap was a steady 2 frames per block, and the `suicide` gap was 100 frames
concentrated in a *single* block out of 100. A total-only check would read as "99% correct" while
one block was badly wrong.

**Current result** — Robinhood Chain, blocks 25899000–25899099:

```
blocks=100  rpc_frames=8567  firehose_frames=8567  delta=0
blocks with a mismatch: 0
```

### Progression

| | frames vs RPC |
|---|---|
| initial | −2.47% |
| after `Block.system_calls` | −1.17% (one block) |
| after `Call.suicide` expansion | **0** |

## End-to-end

Index a fixed range twice into the same schema, wiping between runs, with identical catchup batch
size and concurrency. Completion means **fully indexed including traces**: all blocks present,
`pending_block_operations` drained, internal transaction count stable. Stopping at "all blocks
present" would compare blocks-only against blocks-plus-traces and flatter the Firehose path
substantially, since traces arrive asynchronously on the RPC path.

**Result** — Robinhood Chain, Blockscout defaults (`INDEXER_CATCHUP_BLOCKS_BATCH_SIZE=10`,
`CONCURRENCY=10`), connector on 8 workers.

5,000 blocks (25890000–25894999):

| run | elapsed | blocks/s | txs | logs | internal txs |
|---|---|---|---|---|---|
| JSON-RPC baseline | 207s | 24.2 | 30,567 | 100,781 | 360,444 |
| **Firehose** | **121s** | **41.3** | 30,567 | 100,781 | **360,444** |

**1.71x**, with every count identical.

500 blocks (25899000–25899499), showing how the earlier defects were found and closed:

| run | elapsed | txs | logs | internal txs |
|---|---|---|---|---|
| JSON-RPC baseline | 41s | 3640 | 9739 | 38,676 |
| Firehose, 1 worker, pre-fixes | 50s | 3640 | 9739 | 37,576 |
| Firehose, 8 workers, `system_calls` | 29s | 3640 | 9739 | 38,576 |
| Firehose, 8 workers, all fixes | 29s | 3640 | 9739 | **38,676** |

The advantage grows with range size — 1.41x over 500 blocks, 1.71x over 5,000 — because per-stream
setup amortises while the node's per-block trace call does not. Extrapolating the 5,000-block rates
to Robinhood's ~25.9M blocks: ~7.3 days via Firehose against ~12.4 days via RPC, on one indexer
with default concurrency.

`pending_block_operations` stays at 0 for the whole Firehose run: traces are imported in the same
transaction that creates the queue entries, so the node's tracer is never asked for anything.

### Independent cross-check

Block hashes, transaction counts and gas figures were also compared against the **public Robinhood
Blockscout instance**, which is populated independently:

| block | official | ours |
|---|---|---|
| 25899760 | 4 txs, gas 550756 | 4 txs, gas 550756 |
| 25899761 | 6 txs, gas 635204 | 6 txs, gas 635204 |
| 25899762 | 8 txs, gas 1212323 | 8 txs, gas 1212323 |

Internal transactions for the busiest transaction in the sample: 211 nested on both sides. (Our
database holds 212 — the extra row is the top-level trace, which the API excludes by convention.)

## Throughput notes

The connector, not Firehose, is the ceiling. Decoding protobuf and re-encoding JSON is CPU-bound
and pins a single core:

| | blocks/s |
|---|---|
| 1 worker, 1 request | 16.1 |
| 1 worker, 5 concurrent requests | 15.8 (**0.99x** — no gain) |
| 8 workers, 8 concurrent requests | ~90 (**5.7x**) |

A single-process connector caps the whole pipeline no matter how many ranges Blockscout requests
concurrently. Run at least one worker per two cores.

Interpretation caveats, both of which understate the Firehose advantage:

- The baseline is a **well-provisioned archive endpoint with `debug_traceBlockByNumber` enabled**.
  Many hosted RPCs do not expose `debug_*` at all, in which case there is no baseline to compare —
  Blockscout simply cannot backfill internal transactions.
- Measured at 5,000 blocks. The gap widened from 1.41x to 1.71x going from 500 to 5,000, so
  larger backfills should do better still.

## Reproducing

```bash
# connector
cd dev/firehose && npm install
FIREHOSE_ENDPOINT=<host>:443 FIREHOSE_API_KEY=<key> PORT=8082 FIREHOSE_WORKERS=8 \
  node firehose-sidecar.js

# baseline
export ETHEREUM_JSONRPC_HTTP_URL=<archive-rpc>
export ETHEREUM_JSONRPC_TRACE_URL=<archive-rpc>
unset INDEXER_FIREHOSE_URL
mix run --no-halt

# firehose, same range, wiped database
export INDEXER_FIREHOSE_URL=http://127.0.0.1:8082
mix run --no-halt
```

Then compare with `dev/firehose/verify.sql`, which emits row counts and a stable fingerprint of
blocks, transactions and internal transactions for direct diffing between runs.

## Open items

- **CREATE2** is recorded as `:create`. `sf.ethereum.type.v2.CallType` has no `CREATE2` member.
- **Zero-value selfdestruct beneficiaries** are unrecoverable — no balance moved, so Firehose
  records no refund to attribute.
- Parity is verified on **Arbitrum Orbit**. Other chain families will have their own system-call
  conventions and should be re-validated frame-by-frame before use.
