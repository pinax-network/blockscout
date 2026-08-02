# What still needs a node, and how much of it Firehose could absorb

Replacing block/receipt/trace fetching removes the *heaviest* node calls, but not the *most
numerous*. This measures what is left and how much of it an extended block could serve.

All figures are from Robinhood Chain: 2,000 blocks (25899000–25900999, 16,283 transactions) for
the payload and coverage measurements, and 1,000 blocks for the sample verified against `eth_call`.
Reproduce with `dev/firehose/analyze-coverage.js`.

## Design rule: derive only what is *recorded*, never what is *inferred*

Anything not provably exact falls back to `eth_call`/`eth_getBalance`. That rule draws a clean line
through this analysis, and it excludes token balances.

| Source | Nature | Verified vs node |
|---|---|---|
| `balance_changes` → `eth_getBalance` | recorded state | **100.00%** (400/400) |
| `code_changes` → `eth_getCode` | recorded state | recorded, same class |
| `nonce_changes` → nonces | recorded state | recorded, same class |
| `storage_changes` → `balanceOf` | **inferred** | 94.2% best case — excluded |

Recorded fields are what the node itself wrote down. Inferring `balanceOf` means guessing that a
storage word *is* the balance, and that guess cannot be made safe — see below.

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
`balanceOf` for, 80.5% resolve to a storage slot and **48.3% survive validation gates**.

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

A first pass over 60 samples showed 98.3%; that was a small-sample artifact. Ungated accuracy over
599 samples is 71.9%, dominated by packed slots. Three self-contained gates were then added:

1. **Delta agreement** — the storage word must move by exactly the amount in the `Transfer` log.
2. **Unpacked proof** — a word going `0 → exactly the amount received` proves nothing else shares
   it, certifying that `(token, slot)`.
3. **Final write** — must be the highest-`ordinal` write to that word in the block, tracked across
   *all* writes including unresolvable ones, since `eth_call` returns end-of-block state.

Gated accuracy reaches **94.2%** (752/798) at 48.3% coverage. It does not reach 100%, and the
reason is structural.

#### Why the last 6% cannot be closed

The residual failures are **yield-bearing tokens**, where `balanceOf()` applies an accrual factor
at read time rather than returning a stored number:

```
derived  = 5074002286930471045
eth_call = 5073938167231311660     ratio 1.0000126
```

Stored principal moves by exactly the transferred amount, so gate 1 passes; the read then adds
accrual, so the absolute is wrong. Nothing in the block distinguishes this from a plain balance.

Per-token certification does not rescue it: of 68 tokens observed, **4 were mixed** — correct at
some blocks and wrong at others, because accrual is time-dependent, not token-dependent. A token
can pass a probe and be wrong an hour later.

Under a 100%-or-fall-back rule, `balanceOf` derivation is therefore **excluded entirely**.

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
| `balanceOf` | 11.0 | excluded — cannot be proven exact | 11.0 |
| `eth_getCode` | sporadic | 100% | 0 |
| `tokenURI` | 1.9 | 0% | 1.9 |
| token metadata | one-time/token | 0% | one-time |

Applying the rule — derive only recorded state, fall back otherwise — **~51% of recurring
per-block node calls are replaceable at verified 100% accuracy**, essentially all of it
`eth_getBalance` (13.5 calls/block, 400/400 exact).

`balanceOf` is the other half and is excluded on principle: a gated derivation reaches 94.2%, but
the failures are undetectable from block data and a wrong balance is worse than an extra RPC call.

That is a real reduction but **not** node elimination. The honest positioning: Firehose removes the
*expensive* calls (`debug_traceBlockByNumber`, which many providers do not expose) outright, and
removes the most frequent cheap one (`eth_getBalance`). It does not meaningfully reduce `eth_call`.

None of the balance/code/nonce derivation is implemented. It is scoped here because it changes
what the integration is worth, and because the measurement is cheap to redo on another chain —
coverage is a property of the token contracts on that chain, not of Firehose.
