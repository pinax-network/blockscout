# What still needs a node, and how much of it Firehose could absorb

Replacing block/receipt/trace fetching removes the *heaviest* node calls, but not the *most
numerous*. This measures what is left and how much of it an extended block could serve.

All figures are from Robinhood Chain: 2,000 blocks (25899000–25900999, 16,283 transactions) for
the payload and coverage measurements, and 1,000 blocks for the sample verified against `eth_call`.
Reproduce with `dev/firehose/analyze-coverage.js`.

## The residual load

Blockscout's enrichment fetchers issue one call per row of work discovered while importing blocks:

Rows below are what Blockscout actually recorded indexing 500 blocks; each row is one call its
enrichment fetchers would issue.

| Work | Rows over 500 blocks | Per block | RPC method |
|---|---|---|---|
| Native balances | 7,587 | **15.2** | `eth_getBalance` |
| Token balances | 4,304 | **8.6** | `eth_call` → `balanceOf` |
| NFT metadata | 944 | **1.9** | `eth_call` → `tokenURI` |
| Token metadata | 209 tokens × ~4 | one-time per token | `eth_call` → `name`/`symbol`/`decimals`/`totalSupply` |
| Contract code | on deployment | sporadic | `eth_getCode` |

That is roughly **26 recurring node calls per block**, against ~1.2 calls per block for the block
data itself once batching is accounted for.

So by *call count* the enrichment tail is the larger workload by an order of magnitude. By *cost*
it is not close — a `balanceOf` is a cheap point read, while `debug_traceBlockByNumber` on a block
with 77 internal transactions is expensive enough that many providers do not expose it at all.
Both framings matter: Firehose removes the expensive calls, not the frequent ones.

## What an extended block already contains

Measured over 2,000 Robinhood blocks, from `sf.ethereum.type.v2`:

| Field | Total | Per block |
|---|---|---|
| `keccak_preimages` | 255,034 | 127.5 |
| `storage_changes` | 162,142 | 81.1 |
| `balance_changes` | 79,229 | 39.6 |
| `nonce_changes` | 14,871 | 7.4 |
| `account_creations` | 519 | 0.3 |
| `code_changes` | 300 | 0.2 |

### Directly replaceable

| Node call | Extended block source |
|---|---|
| `eth_getBalance` | `balance_changes` — carries old and new value, so absolute balances, not just deltas |
| `eth_getCode` | `code_changes` on the deploying call |
| nonce lookups | `nonce_changes` |

That covers the single largest line item — native balances, 12–15 calls/block — outright, and
contract code and nonces with it.

### Partly derivable: `balanceOf` — ~30%, and exact when it resolves

An ERC-20 balance lives at `keccak256(abi.encode(holder, slot))`. Firehose records the storage
write *and* the keccak preimage that produced the key, so the holder and mapping slot can be
recovered without knowing the contract's layout in advance:

```
storage_change.key -> keccak_preimages[key] -> abi.encode(holder, slot)
                                                 ^^^^^^         ^^^^
                                          bytes 12..32     bytes 32..64
```

**Coverage, measured over 2,000 blocks:** of 21,995 `(token, holder)` pairs Blockscout would issue
`balanceOf` for, **25.8% resolve** from storage. Over a 1,000-block window the figure is 29.8%.
This is the number that matters, and it is far below what the mechanism suggests in isolation.

**Accuracy, verified against the node:** every derived balance was checked with an actual
`eth_call balanceOf(holder)` at the same block.

```
verified 599 derived balances against eth_call balanceOf()   (46 tokens)
  exact match    : 431
  mismatch       : 168
     packed slot : 161
     other       :   7
  accuracy       : 71.9%
```

A first pass over 60 samples showed 98.3%; that was a small-sample artifact and did not survive
widening. **Packed storage slots are common, not exceptional** — 27% of resolved balances share
their 32-byte word with another field, so reading the whole word gives a number that is wrong by
orders of magnitude.

Compounding the two figures, the share of `balanceOf` calls that can be replaced *correctly and
generically* is `25.8% × 71.9%` ≈ **19%**.

`storage_changes` carry `old_value` and `new_value`, so results are **absolute balances**, not
deltas — no accumulation from genesis required.

#### Two things this got wrong first, worth repeating

**Storage attribution.** `StorageChange` has its **own `address` field**, and it is not the call's
`address`. Under `DELEGATECALL` — i.e. every proxy-pattern token — storage belongs to the caller
while `call.address` is the implementation. Attributing to the call raised the miss rate by nine
percentage points (16.5% → 25.8% once corrected).

**Intra-block ordering.** A balance can be written several times in one block; `eth_call` returns
end-of-block state. Take the highest-`ordinal` write per `(block, token, holder)`. One observed
holder went `0 → 86843071998124 → 0` inside a single block, and comparing the intermediate write
against `eth_call` looks like a data error when it is not.

This is only a partial fix, and explains the 7 non-packed mismatches: the last *resolvable* write
is not always the last *actual* write. If a later write in the same block has no usable preimage,
a stale intermediate value is kept. Those mismatches are small relative differences
(e.g. `5074002286930471045` vs `5073938167231311660`) rather than the order-of-magnitude errors
packing produces.

#### Why the other ~70% does not resolve

- **Packed slots — the dominant failure.** 161 of 168 mismatches. A slot holding more than one
  field reads back as nonsense: derived `36893488147419103234`, actual `2`, because
  `36893488147419103234 & (2⁶⁴−1) == 2`. Resolving these needs per-contract layout knowledge,
  which defeats the point of a generic derivation.
- **Non-canonical layouts.** ERC-721 keys ownership by token id, not holder; ERC-1155 uses nested
  mappings; some tokens use structs or custom accounting.
- **No usable preimage.** Only writes whose key resolves to a 64-byte `abi.encode(address, slot)`
  preimage can be attributed at all.
- **Idle holders.** Only balances that *changed* in the window appear. Seeding a holder untouched
  since before the window still needs one `eth_call`.

### Not derivable

`name()`, `symbol()`, `decimals()`, `tokenURI()`, `totalSupply()` are usually returned from
bytecode or computed, not read from a storage slot the block records. These genuinely require
`eth_call`.

The saving grace is that they are **one-time per token** rather than per block: 209 tokens across
500 blocks, and each is queried once for the life of the index.

## Conclusion

Measured, per block, over 2,000 blocks:

| Work | Needed/block | Derivable | Residual/block |
|---|---|---|---|
| `eth_getBalance` | 13.5 | 100% | 0 |
| `balanceOf` | 11.0 | 25.8% resolve × 71.9% correct ≈ **19%** | 8.9 |
| `eth_getCode` | sporadic | 100% | 0 |
| `tokenURI` | 1.9 | 0% | 1.9 |
| token metadata | one-time/token | 0% | one-time |

**Roughly 59% of the recurring per-block node calls are addressable — and essentially all of that
is `eth_getBalance`.** `balanceOf` derivation contributes about 2 of the ~26 calls/block once both
coverage and correctness are applied, and buying those 2 costs per-contract storage-layout
knowledge. On this evidence it is not worth building generically; native balances, contract code
and nonces are.

That is a real reduction but **not** node elimination. The honest positioning: Firehose removes the
*expensive* calls (`debug_traceBlockByNumber`, which many providers do not expose) outright, and
removes the most frequent cheap one (`eth_getBalance`). It does not meaningfully reduce `eth_call`.

None of the balance/code/nonce derivation is implemented. It is scoped here because it changes
what the integration is worth, and because the measurement is cheap to redo on another chain —
coverage is a property of the token contracts on that chain, not of Firehose.
