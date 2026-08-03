#!/usr/bin/env node
//
// Derives ERC-20 balances from extended blocks, but only emits those that can be shown correct
// from the block alone. Everything else is reported as "fall back to eth_call".
//
// The problem: a storage word that packs the balance alongside another field reads back wrong by
// orders of magnitude, and nothing about the write says so. Two gates, both self-contained:
//
//   Gate 1 - delta agreement. An ERC-20 Transfer(from,to,value) must move each side's balance by
//            exactly `value`. If the storage word's delta does not equal the net transferred
//            amount, the word is not (only) the balance. Necessary, not sufficient: a packed word
//            whose other fields are untouched still deltas correctly.
//
//   Gate 2 - proof the slot is unpacked. If a holder's word goes 0 -> V and V is exactly the
//            amount received, the whole word is the balance and nothing else shares it. That
//            proves (token, slot) is clean, for this token, for good. Absolute values from a
//            proven-clean slot can be trusted; a slot never proven clean is never trusted.
//
//   FIREHOSE_ENDPOINT=... FIREHOSE_API_KEY=... node derive-gated.js <start> <count> [out.json]

const path = require("path");
const grpc = require("@grpc/grpc-js");
const protoLoader = require("@grpc/proto-loader");
const protobuf = require("protobufjs");

const ENDPOINT = process.env.FIREHOSE_ENDPOINT;
const API_KEY = process.env.FIREHOSE_API_KEY || "";
const START = parseInt(process.argv[2], 10);
const COUNT = parseInt(process.argv[3], 10);
const OUT = process.argv[4];
const SAMPLE_TARGET = parseInt(process.env.SAMPLE_TARGET || "600", 10);
const TRANSFER = "ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";

const OPTS = { keepCase: false, longs: String, enums: String, defaults: true, oneofs: true,
               includeDirs: [path.join(__dirname, "proto")] };
const pkg = grpc.loadPackageDefinition(protoLoader.loadSync("sf/firehose/v2/firehose.proto", OPTS));
const root = new protobuf.Root();
root.resolvePath = (_o, t) => t.startsWith("google/")
  ? protobuf.util.path.resolve(path.join(__dirname, "node_modules/protobufjs/"), t)
  : path.join(__dirname, "proto", t);
root.loadSync("sf/ethereum/type/v2/type.proto", { keepCase: false });
const EthBlock = root.lookupType("sf.ethereum.type.v2.Block");

const hex = (b) => (b && b.length ? Buffer.from(b).toString("hex") : "");
const num = (b) => (b && b.length ? BigInt("0x" + Buffer.from(b).toString("hex")) : 0n);

const cleanSlots = new Set();          // `${token}:${slot}` proven to hold nothing but the balance
const accepted = new Map();            // gated, trustworthy absolute balances
const stat = { blocks: 0, needed: 0, resolvedPairs: new Set(), acceptedPairs: new Set(),
               gate1Fail: 0, gate2Fail: 0, gate3Fail: 0, accepted: 0 };

function analyze(block) {
  const blockNum = Number(block.number);
  stat.blocks++;

  // Gate 3 needs to know the final write to each storage word in the *whole block*, including
  // writes that no gate will accept and writes whose preimage never resolves. Keyed on the raw
  // (contract, key), so it does not depend on understanding the slot at all. Without this, the
  // last *accepted* write gets emitted as if it were the last actual write, and the value is
  // stale - which is exactly what the remaining mismatches were.
  const finalOrdinal = new Map();
  for (const t of block.transactionTraces || [])
    for (const c of t.calls || [])
      for (const sc of c.storageChanges || []) {
        const wk = `${hex(sc.address) || hex(c.address)}:${hex(sc.key)}`;
        const ord = Number(sc.ordinal || 0);
        if (ord > (finalOrdinal.get(wk) ?? -1)) finalOrdinal.set(wk, ord);
      }

  for (const t of block.transactionTraces || []) {
    const calls = t.calls || [];

    const preimages = new Map();
    for (const c of calls)
      for (const [k, v] of Object.entries(c.keccakPreimages || {}))
        preimages.set(k.replace(/^0x/, "").toLowerCase(), v.replace(/^0x/, "").toLowerCase());

    // net ERC-20 movement per (token, holder) across this transaction, and what each holder
    // received (used to prove a slot is unpacked)
    const net = new Map(), received = new Map(), needed = new Set();
    for (const c of calls) {
      for (const lg of c.logs || []) {
        const tp = (lg.topics || []).map(hex);
        if (tp[0] !== TRANSFER || tp.length < 3) continue;
        const token = hex(lg.address);
        const value = num(lg.data);
        const from = tp[1].slice(24), to = tp[2].slice(24);
        for (const [h, sign] of [[from, -1n], [to, 1n]]) {
          if (/^0+$/.test(h)) continue;
          const k = `${token}:${h}`;
          needed.add(k);
          net.set(k, (net.get(k) || 0n) + sign * value);
          if (sign === 1n) received.set(k, (received.get(k) || 0n) + value);
        }
      }
    }
    stat.needed += needed.size;

    for (const c of calls) {
      for (const sc of c.storageChanges || []) {
        const token = hex(sc.address) || hex(c.address);
        const img = preimages.get(hex(sc.key));
        if (!img || img.length !== 128) continue;
        const holder = img.slice(24, 64);
        const slot = BigInt("0x" + img.slice(64)).toString();
        const k = `${token}:${holder}`;
        if (!needed.has(k)) continue;
        stat.resolvedPairs.add(`${blockNum}:${k}`);

        const oldV = num(sc.oldValue), newV = num(sc.newValue);
        const slotKey = `${token}:${slot}`;
        const wordKey = `${token}:${hex(sc.key)}`;

        // Gate 2 proof: word went 0 -> exactly what was received => nothing else lives in it
        if (oldV === 0n && received.get(k) === newV && newV > 0n) cleanSlots.add(slotKey);

        // Gate 1: the word must move by exactly the net transferred amount
        if (newV - oldV !== net.get(k)) { stat.gate1Fail++; continue; }
        // Gate 2: absolute value only trusted from a slot proven to hold the balance alone
        if (!cleanSlots.has(slotKey)) { stat.gate2Fail++; continue; }
        // Gate 3: this must be the final write to that word in the block, or the value is stale
        if (Number(sc.ordinal || 0) !== finalOrdinal.get(wordKey)) { stat.gate3Fail++; continue; }

        const ord = Number(sc.ordinal || 0);
        const key = `${blockNum}:${k}`;
        // acceptance is the real measurement; the sample cap below only bounds what we write out
        stat.acceptedPairs.add(key);
        const prev = accepted.get(key);
        if (!prev && accepted.size >= SAMPLE_TARGET) continue;
        if (!prev || ord > prev.ordinal) {
          if (!prev) stat.accepted++;
          accepted.set(key, { block: blockNum, token: "0x" + token, holder: "0x" + holder,
                              slot, ordinal: ord, newValue: newV.toString() });
        }
      }
    }
  }
}

const client = new pkg.sf.firehose.v2.Stream(ENDPOINT, grpc.credentials.createSsl(), {
  "grpc.max_receive_message_length": 100 * 1024 * 1024, "grpc.keepalive_time_ms": 30000 });
const md = new grpc.Metadata();
if (API_KEY) md.set("x-api-key", API_KEY);

const stream = client.Blocks(
  { startBlockNum: START, stopBlockNum: START + COUNT - 1, finalBlocksOnly: true }, md);
stream.on("data", (r) => {
  analyze(EthBlock.toObject(EthBlock.decode(r.block.value),
    { enums: String, longs: String, bytes: Buffer, defaults: true }));
  if (stat.blocks % 250 === 0) process.stderr.write(`  ...${stat.blocks}\n`);
});
stream.on("error", (e) => { console.error("stream error:", e.details || e.message); process.exit(1); });
stream.on("end", () => {
  const pct = (a, b) => (b ? ((100 * a) / b).toFixed(1) + "%" : "n/a");
  console.log(`\n=== ${stat.blocks} blocks (${START}..${START + stat.blocks - 1}) ===\n`);
  console.log(`  balanceOf pairs needed     ${stat.needed}`);
  console.log(`  resolved to a storage slot ${stat.resolvedPairs.size}   ${pct(stat.resolvedPairs.size, stat.needed)}`);
  console.log(`  rejected by gate 1 (delta)   ${stat.gate1Fail}`);
  console.log(`  rejected by gate 2 (packed)  ${stat.gate2Fail}`);
  console.log(`  rejected by gate 3 (stale)   ${stat.gate3Fail}`);
  console.log(`  ACCEPTED pairs             ${stat.acceptedPairs.size}   ${pct(stat.acceptedPairs.size, stat.needed)} of need`);
  console.log(`  proven-clean (token,slot)  ${cleanSlots.size}`);
  if (OUT) {
    require("fs").writeFileSync(OUT, JSON.stringify([...accepted.values()], null, 2));
    console.log(`\n  wrote ${accepted.size} accepted balances to ${OUT}`);
  }
  process.exit(0);
});
