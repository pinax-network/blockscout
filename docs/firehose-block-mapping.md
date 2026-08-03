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
| `withdrawalsRoot` | `header.withdrawals_root` |
| `blobGasUsed` / `excessBlobGas` | same-named optional Cancun header fields |
| `parentBeaconBlockRoot` | `header.parent_beacon_root` |
| `requestsHash` | `header.requests_hash` (Prague) |
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
| `accessList` | `access_list`, including every storage key |
| `maxFeePerBlobGas` | `blob_gas_fee_cap` (type 3) |
| `blobVersionedHashes` | `blob_hashes` (type 3) |
| `authorizationList` | `set_code_authorizations` signature tuple fields (type 4) |

Arbitrum transaction types matter on Orbit chains: `TRX_TYPE_ARBITRUM_DEPOSIT` = 100,
`_UNSIGNED` = 101, `_CONTRACT` = 102, `_RETRY` = 104, `_SUBMIT_RETRYABLE` = 105,
`_INTERNAL` = 106, `_LEGACY` = 120.

Robinhood's Arbitrum extended stream currently omits `max_fee_per_gas` and
`max_priority_fee_per_gas` for type-2 transactions. The connector keeps the recorded effective
`gasPrice` and omits those two JSON-RPC keys instead of inventing values; Ethereum typed
transactions remain fail-closed when either field is missing. The upstream gap is tracked in
[issue #4](https://github.com/pinax-network/blockscout/issues/4).

Cancun blob transactions map to type `0x3`; Prague `TRX_TYPE_SET_CODE` transactions map to `0x4`.
Each EIP-7702 authorization emits `chainId`, `address`, `nonce`, `yParity`, `r` and `s`. Firehose's
derived `authority` and `discarded` metadata are not part of the JSON-RPC transaction object.

The Optimism deposit (`0x7e`) and Polygon state-sync (`0xc8`) enum values are recognized so they
can never silently fall back to legacy type `0x0`. Those chain families remain runtime-blocked:
the current protobuf does not carry all node-specific deposit fields and they do not yet have
end-to-end Blockscout database parity.

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
| `blobGasUsed` / `blobGasPrice` | same-named `TransactionReceipt` fields (type 3) |

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
0 by convention, type `TRX_TYPE_ARBITRUM_INTERNAL`). The connector locates that transaction by
type rather than assuming its position. They form their own `index`/`parent_index` tree. Ignoring
them cost 2 internal transactions per block — ~2.5% of the total on Robinhood Chain.

Ethereum Cancun/Prague protocol system calls have no transaction and are not returned by
`debug_traceBlockByNumber`, so they are deliberately not attached to a user transaction. Their
committed balance effects are still included in `balanceChanges`.

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
- [ ] optional fork fields emitted only when present; never substitute zero for an absent field
- [ ] `logIndex` from `blockIndex`, not `index`
- [ ] `status`/`gasUsed` come off the trace, not the receipt
- [ ] `receipt_root` is singular in the schema, `receiptsRoot` in JSON-RPC
- [ ] a receipt for **every** transaction — Blockscout looks them up with `Map.fetch!/2` and will
      raise on a missing one
- [ ] Arbitrum `Block.system_calls` attached to the explicit ArbOS system transaction
- [ ] `Call.suicide` expanded into a second frame
- [ ] unknown and unsupported chain-specific transaction types fail the range instead of becoming legacy
