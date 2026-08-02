# Firehose block → JSON-RPC field mapping

How one `sf.ethereum.type.v2.Block` becomes the three JSON-RPC payloads Blockscout parses. This is
the reference for reimplementing or auditing the connector.

Everything here is derived from the schemas in `dev/firehose/proto/`, re-syncable with
`dev/firehose/sync-protos.sh`. Note the two schemas live in **different Buf modules**:

| Module | Provides |
|---|---|
| [`streamingfast/firehose`](https://buf.build/streamingfast/firehose) | `sf.firehose.v2.Stream` service |
| [`streamingfast/firehose-ethereum`](https://buf.build/streamingfast/firehose-ethereum) | `sf.ethereum.type.v2.Block` |

`Response.block` is a `google.protobuf.Any` that must be unpacked against the second one.

## Stream request

```json
{ "startBlockNum": 1000, "stopBlockNum": 1099, "finalBlocksOnly": true }
```

**Both bounds are inclusive** — confirmed in the proto (`stop_block_num`: "the stream will close
**after** that block has passed so the boundary is **inclusive**") and empirically (`25899760..25899762`
yields exactly 3 blocks). Non-overlapping partitions are therefore `[i*N, (i+1)*N - 1]`.

Field names are camelCase when the schema is loaded with `keepCase: false`. Sending `start_block_num`
in that mode is silently ignored and the stream starts from block 0.

## Encoding conventions

| Firehose | JSON-RPC | Note |
|---|---|---|
| `bytes` (hash, address) | `0x` + hex | empty → `"0x"` for **data** fields |
| `bytes` (v, r, s) | `0x` + hex quantity | empty → **`"0x0"`**, not `"0x"` — see gotchas |
| `BigInt { bytes }` | `0x` + hex quantity | big-endian; empty → `"0x0"` |
| `uint64` | `0x` + hex quantity | |
| `google.protobuf.Timestamp` | `0x` + hex seconds | |
| enum | string name | load with `enums: String` |

Protobuf omits default values, so a decoder must fill them (`parentIndex` absent means 0, etc.).

## Block header → `eth_getBlockByNumber`

| JSON-RPC | Source |
|---|---|
| `hash` | `Block.hash` |
| `number` | `Block.number` |
| `size` | `Block.size` |
| `parentHash` | `header.parent_hash` |
| `sha3Uncles` | `header.uncle_hash` |
| `miner` | `header.coinbase` |
| `stateRoot` | `header.state_root` |
| `transactionsRoot` | `header.transactions_root` |
| `receiptsRoot` | `header.receipt_root` — note the singular name |
| `logsBloom` | `header.logs_bloom` |
| `difficulty` / `totalDifficulty` | `header.difficulty` / `header.total_difficulty` |
| `gasLimit` / `gasUsed` | `header.gas_limit` / `header.gas_used` |
| `timestamp` | `header.timestamp` (Timestamp → seconds) |
| `extraData` | `header.extra_data` |
| `mixHash` | `header.mix_hash` |
| `nonce` | `header.nonce`, **padded to 8 bytes** |
| `baseFeePerGas` | `header.base_fee_per_gas` |
| `uncles` | `Block.uncles` |
| `withdrawals` | `Block.withdrawals` |
| `transactions` | from `Block.transaction_traces`, below |

## TransactionTrace → transaction object

| JSON-RPC | Source |
|---|---|
| `hash` / `from` / `to` / `nonce` / `input` | same-named `TransactionTrace` fields |
| `value` / `gasPrice` / `maxFeePerGas` / `maxPriorityFeePerGas` | same-named (`BigInt`) |
| `gas` | `gas_limit` |
| `transactionIndex` | `index` |
| `blockHash` / `blockNumber` | from the enclosing block |
| `type` | `Type` enum → numeric (see below) |
| `v` / `r` / `s` | same-named — **quantity encoding** |

Arbitrum transaction types matter on Orbit chains: `TRX_TYPE_ARBITRUM_DEPOSIT` = 100,
`_UNSIGNED` = 101, `_CONTRACT` = 102, `_RETRY` = 104, `_SUBMIT_RETRYABLE` = 105,
`_INTERNAL` = 106, `_LEGACY` = 120.

## Receipts → `eth_getBlockReceipts`

`TransactionReceipt` carries only `state_root`, `cumulative_gas_used`, `logs_bloom`, `logs`,
`blob_gas_used`, `blob_gas_price`. Everything else is synthesised:

| JSON-RPC | Source |
|---|---|
| `cumulativeGasUsed` / `logsBloom` / `logs` | `TransactionTrace.receipt` |
| `transactionHash` / `transactionIndex` / `from` / `to` | `TransactionTrace` |
| `gasUsed` | `TransactionTrace.gas_used` — **not** on the receipt |
| `effectiveGasPrice` | `TransactionTrace.gas_price` |
| `status` | `TransactionTrace.status` — `SUCCEEDED` → `0x1`, else `0x0` |
| `blockHash` / `blockNumber` | enclosing block |
| `contractAddress` | `address` of the top-level `CREATE` call, when `to` is empty |

### Logs

| JSON-RPC | Source |
|---|---|
| `address` / `topics` / `data` | same-named `Log` fields |
| `logIndex` | **`Log.blockIndex`** — JSON-RPC `logIndex` is block-scoped; `Log.index` is transaction-scoped |
| `transactionHash` / `transactionIndex` / `blockHash` / `blockNumber` | context |
| `removed` | always `false` (final blocks only) |

## Calls → `debug_traceBlockByNumber` (callTracer)

The largest transformation. Firehose gives a **flat** list with `index` / `parent_index`; callTracer
wants a **nested** tree.

```
byIndex = { call.index -> frame }
for each call:
    parent = byIndex[call.parent_index]      # parent_index 0/absent == root
    parent ? parent.calls.push(frame) : root = frame
```

Per-frame fields:

| callTracer | Source |
|---|---|
| `from` | `Call.caller` |
| `to` | `Call.address` |
| `value` | `Call.value` |
| `gas` | `Call.gas_limit` |
| `gasUsed` | `Call.gas_consumed` |
| `input` | `Call.input` |
| `output` | `Call.return_data` |
| `error` | `Call.failure_reason`, when `status_failed` or `status_reverted` |
| `type` | `Call.call_type`, mapped below |

`CallType` → callTracer `type`: `CALL`→`CALL`, `CALLCODE`→`CALLCODE`, `DELEGATE`→`DELEGATECALL`,
`STATIC`→`STATICCALL`, `CREATE`→`CREATE`.

### Three things that are easy to miss

These accounted for **every** frame-count difference against a node's tracer. Each was found by
diffing frame-by-frame; see [firehose-parity.md](firehose-parity.md).

**1. `Block.system_calls` — outside `transaction_traces` entirely.**
Chain-level system operations live in their own top-level field. A node's tracer reports them
nested inside the chain's system transaction (on Arbitrum, the ArbOS internal transaction at index
0, type `TRX_TYPE_ARBITRUM_INTERNAL`). They form their own `index`/`parent_index` tree. Ignoring
them cost 2 internal transactions per block — ~2.5% of the total on Robinhood Chain.

**2. `Call.suicide` is one Firehose call but two tracer frames.**
Firehose flags the self-destructing contract with `suicide: true` on the call that created or
entered it. A node emits a *separate* `SELFDESTRUCT` frame nested inside. Expand it:

- `from` = `Call.address`
- `value` = the `REASON_SUICIDE_WITHDRAW` balance change's old value
- `to` = the `REASON_SUICIDE_REFUND` balance change's address

**A zero-value selfdestruct records no refund**, so the beneficiary is not recoverable in that
case and `to` must be omitted. This is a genuine limitation, not an implementation shortcut.

**3. `CallType` has no `CREATE2`.**
The enum stops at `CREATE` — the schema itself carries the comment `// create2 ? any other form of
calls?`. A create2 is therefore indistinguishable from a create and Blockscout records it as
`:create`. Recovering it would mean inferring from `Call.keccak_preimages`. **Open gap.**

## Gotchas checklist

- [ ] camelCase request fields, or the stream silently starts at block 0
- [ ] `stop_block_num` is inclusive
- [ ] `v`/`r`/`s` empty → `0x0`; Blockscout runs these through `quantity_to_integer/1`, which
      rejects a bare `"0x"`
- [ ] block `nonce` padded to 8 bytes
- [ ] `logIndex` from `blockIndex`, not `index`
- [ ] `status`/`gasUsed` come off the trace, not the receipt
- [ ] `receipt_root` is singular in the schema, `receiptsRoot` in JSON-RPC
- [ ] a receipt for **every** transaction — Blockscout looks them up with `Map.fetch!/2` and will
      raise on a missing one
- [ ] `Block.system_calls` attached to the system transaction
- [ ] `Call.suicide` expanded into a second frame
