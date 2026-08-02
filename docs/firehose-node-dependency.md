# What still needs a node, and how much of it Firehose could absorb

Replacing block/receipt/trace fetching removes the *heaviest* node calls, but not the *most
numerous*. This measures what is left and how much of it an extended block could serve.

All figures are from Robinhood Chain, blocks 25899000–25899499 (500 blocks, 3,640 transactions),
indexed via Firehose.

## The residual load

Blockscout's enrichment fetchers issue one call per row of work discovered while importing blocks:

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

Measured per Robinhood block, from `sf.ethereum.type.v2`:

| Field | Per block |
|---|---|
| `balance_changes` | 47.5 |
| `storage_changes` | 93.1 |
| `keccak_preimages` | 122.8 |
| `gas_changes` | 231.4 |
| `nonce_changes` | 8.5 |
| `code_changes` | on deployment |
| `account_creations` | on creation |

### Directly replaceable

| Node call | Extended block source |
|---|---|
| `eth_getBalance` | `balance_changes` — carries old and new value, so absolute balances, not just deltas |
| `eth_getCode` | `code_changes` on the deploying call |
| nonce lookups | `nonce_changes` |

That covers the single largest line item (15.2 calls/block) outright.

### Derivable, with work: `balanceOf`

An ERC-20 balance lives at `keccak256(abi.encode(holder, slot))`. Firehose records the storage
write *and* the keccak preimage that produced the key, so the holder and mapping slot can be
recovered without knowing the contract's layout in advance:

```
storage_change.key -> keccak_preimages[key] -> abi.encode(holder, slot)
                                                 ^^^^^^         ^^^^
                                          bytes 12..32     bytes 32..64
```

**Verified on live Robinhood data.** Resolving storage changes on transactions carrying ERC-20
`Transfer` logs against the holders named in those logs:

```
token 0xc6b81b429797e0f555  holder 0x760a4e1016bae903ca  mapping slot 51
   balance 189588857555763671 -> 189565235526820016   (delta -23622028943655)
token 0xc6b81b429797e0f555  holder 0xcaf681a66d02060134  mapping slot 51
   balance                 0 ->      23622028943655   (delta +23622028943655)
```

Both sides of one transfer, reconstructed from storage alone. `storage_changes` carries
`old_value` and `new_value`, so these are **absolute balances**, not deltas — no accumulation from
genesis required.

Caveats:

- Only holders whose balance *changed* in the indexed window appear. A holder who has been idle
  since before the window still needs one `eth_call` to seed.
- Not every storage change is a balance. In the sample, 189 of 700 resolved to a known transfer
  participant; the rest are allowances and unrelated state. Attribution has to be filtered, not
  assumed.
- Proxy and non-standard token implementations will not all follow the canonical mapping layout.

### Not derivable

`name()`, `symbol()`, `decimals()`, `tokenURI()`, `totalSupply()` are usually returned from
bytecode or computed, not read from a storage slot the block records. These genuinely require
`eth_call`.

The saving grace is that they are **one-time per token** rather than per block: 209 tokens across
500 blocks, and each is queried once for the life of the index.

## Conclusion

The earlier framing — "Firehose replaces the history workload, not the node" — is too pessimistic.
A more accurate split:

| | |
|---|---|
| **Replaced today** | blocks, receipts, logs, traces |
| **Replaceable, not yet built** | native balances, contract code, nonces (direct); token balances (via storage + preimages) |
| **Still needs `eth_call`** | token and NFT metadata — one-time per token, not per block |

Roughly **24 of the ~26 recurring node calls per block are addressable**, leaving a small
one-time-per-token tail. That would take Blockscout from "needs a full archive node alongside
Firehose" to "needs occasional `eth_call` access" — a materially different operational story,
since `eth_call` is available on essentially every RPC provider while `debug_traceBlockByNumber`
is not.

None of this is implemented. It is scoped here because it changes what the integration is worth,
and because the measurement is cheap to redo on another chain.
