#!/usr/bin/env node
//
// Measures how much of Blockscout's eth_call load an extended block could absorb, over a wide
// block range, and emits derived balances for independent verification against eth_call.
//
//   FIREHOSE_ENDPOINT=... FIREHOSE_API_KEY=... node analyze-coverage.js <start> <count> [out.json]
//
// Streams rather than buffering: grpcurl's JSON is ~170KB/block, so a few thousand blocks would be
// unwieldy on disk. This keeps only counters plus a bounded validation sample.

const path = require("path");
const grpc = require("@grpc/grpc-js");
const protoLoader = require("@grpc/proto-loader");
const protobuf = require("protobufjs");

const ENDPOINT = process.env.FIREHOSE_ENDPOINT;
const API_KEY = process.env.FIREHOSE_API_KEY || process.env.PINAX_KEY || "";
const START = parseInt(process.argv[2], 10);
const COUNT = parseInt(process.argv[3], 10);
const OUT = process.argv[4];
const SAMPLE_TARGET = 60;

const TRANSFER = "ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";

const PROTO_OPTS = { keepCase: false, longs: String, enums: String, defaults: true, oneofs: true,
                     includeDirs: [path.join(__dirname, "proto")] };
const firehosePkg = grpc.loadPackageDefinition(
  protoLoader.loadSync("sf/firehose/v2/firehose.proto", PROTO_OPTS));
const root = new protobuf.Root();
root.resolvePath = (_o, t) => t.startsWith("google/")
  ? protobuf.util.path.resolve(path.join(__dirname, "node_modules/protobufjs/"), t)
  : path.join(__dirname, "proto", t);
root.loadSync("sf/ethereum/type/v2/type.proto", { keepCase: false });
const EthBlock = root.lookupType("sf.ethereum.type.v2.Block");

const hex = (b) => (b && b.length ? Buffer.from(b).toString("hex") : "");
const num = (b) => (b && b.length ? BigInt("0x" + Buffer.from(b).toString("hex")) : 0n);

const stat = {
  blocks: 0, transactions: 0, logs: 0, transferLogs: 0,
  storageChanges: 0, balanceChanges: 0, keccakPreimages: 0,
  nonceChanges: 0, codeChanges: 0, accountCreations: 0,
  balanceOfNeeded: 0, balanceOfDerived: 0,
  nativeBalanceNeeded: 0, nativeBalanceDerived: 0,
  codeNeeded: 0, codeDerived: 0,
  tokensSeen: new Set(), holderPairsNeeded: new Set(), holderPairsDerived: new Set(),
  touchedAccounts: new Set(),
};
const samples = [];
const sampleByKey = new Map();  // last write per (block, token, holder), by ordinal

function analyze(block) {
  const blockNum = Number(block.number);
  stat.blocks++;

  for (const t of block.transactionTraces || []) {
    stat.transactions++;
    const calls = t.calls || [];

    // keccak preimages for this transaction: storage key -> abi.encode(holder, slot)
    const preimages = new Map();
    for (const c of calls) {
      for (const [k, v] of Object.entries(c.keccakPreimages || {})) {
        preimages.set(k.replace(/^0x/, "").toLowerCase(), v.replace(/^0x/, "").toLowerCase());
        stat.keccakPreimages++;
      }
    }

    // (token, holder) pairs Blockscout would issue balanceOf for
    const needed = new Set();
    for (const c of calls) {
      for (const lg of c.logs || []) {
        stat.logs++;
        const topics = (lg.topics || []).map(hex);
        if (topics[0] === TRANSFER && topics.length >= 3) {
          stat.transferLogs++;
          const token = hex(lg.address);
          stat.tokensSeen.add(token);
          for (const side of [topics[1], topics[2]]) {
            const holder = side.slice(24);
            if (/^0+$/.test(holder)) continue;         // mint/burn endpoint
            needed.add(`${token}:${holder}`);
          }
        }
      }
    }
    for (const k of needed) { stat.holderPairsNeeded.add(k); stat.balanceOfNeeded++; }

    for (const c of calls) {
      stat.balanceChanges += (c.balanceChanges || []).length;
      stat.nonceChanges += (c.nonceChanges || []).length;
      stat.codeChanges += (c.codeChanges || []).length;
      stat.accountCreations += (c.accountCreations || []).length;

      for (const bc of c.balanceChanges || []) stat.touchedAccounts.add(hex(bc.address));
      for (const cc of c.codeChanges || []) { stat.codeNeeded++; stat.codeDerived++; }

      for (const sc of c.storageChanges || []) {
        stat.storageChanges++;
        // StorageChange carries its own address: for a DELEGATECALL the storage belongs to the
        // caller, not the code being executed, which is exactly the proxy-token case.
        const token = hex(sc.address) || hex(c.address);
        const img = preimages.get(hex(sc.key));
        if (!img || img.length !== 128) continue;      // not a mapping slot we can resolve
        const holder = img.slice(24, 64);
        const slot = BigInt("0x" + img.slice(64));
        const key = `${token}:${holder}`;
        if (!needed.has(key)) continue;                // resolved, but not a balance we needed
        if (!stat.holderPairsDerived.has(key)) stat.balanceOfDerived++;
        stat.holderPairsDerived.add(key);
        const sk = `${blockNum}:${token}:${holder}`;
        const ord = Number(sc.ordinal || 0);
        const prev = sampleByKey.get(sk);
        if (!prev && sampleByKey.size >= SAMPLE_TARGET) continue;
        if (!prev || ord > prev.ordinal) {
          sampleByKey.set(sk, {
            block: blockNum, token: "0x" + token, holder: "0x" + holder,
            slot: slot.toString(), ordinal: ord,
            oldValue: num(sc.oldValue).toString(), newValue: num(sc.newValue).toString(),
          });
        }
      }
    }
  }

  // native balances: every account whose balance moved is known exactly
  stat.nativeBalanceNeeded += stat.touchedAccounts.size;
  stat.nativeBalanceDerived += stat.touchedAccounts.size;
  stat.touchedAccounts.clear();
}

const client = new firehosePkg.sf.firehose.v2.Stream(ENDPOINT, grpc.credentials.createSsl(), {
  "grpc.max_receive_message_length": 100 * 1024 * 1024,
  "grpc.keepalive_time_ms": 30000,
});
const md = new grpc.Metadata();
if (API_KEY) md.set("x-api-key", API_KEY);

const started = Date.now();
const stream = client.Blocks(
  { startBlockNum: START, stopBlockNum: START + COUNT - 1, finalBlocksOnly: true }, md);

stream.on("data", (r) => {
  analyze(EthBlock.toObject(EthBlock.decode(r.block.value),
    { enums: String, longs: String, bytes: Buffer, defaults: true }));
  if (stat.blocks % 250 === 0) process.stderr.write(`  ...${stat.blocks} blocks\n`);
});
stream.on("error", (e) => { console.error("stream error:", e.details || e.message); process.exit(1); });
stream.on("end", () => {
  const n = stat.blocks;
  const per = (x) => (x / n).toFixed(1);
  console.log(`\n=== ${n} blocks (${START}..${START + n - 1}) in ${((Date.now()-started)/1000).toFixed(1)}s ===\n`);
  console.log(`  transactions            ${stat.transactions}  (${per(stat.transactions)}/block)`);
  console.log(`  logs                    ${stat.logs}  (${per(stat.logs)}/block)`);
  console.log(`  ERC-20 Transfer logs    ${stat.transferLogs}  (${per(stat.transferLogs)}/block)`);
  console.log(`  distinct tokens         ${stat.tokensSeen.size}`);
  console.log(`\n  --- extended block payload ---`);
  console.log(`  storage_changes         ${stat.storageChanges}  (${per(stat.storageChanges)}/block)`);
  console.log(`  balance_changes         ${stat.balanceChanges}  (${per(stat.balanceChanges)}/block)`);
  console.log(`  keccak_preimages        ${stat.keccakPreimages}  (${per(stat.keccakPreimages)}/block)`);
  console.log(`  nonce_changes           ${stat.nonceChanges}  (${per(stat.nonceChanges)}/block)`);
  console.log(`  code_changes            ${stat.codeChanges}`);
  console.log(`  account_creations       ${stat.accountCreations}`);
  console.log(`\n  --- eth_call replacement coverage ---`);
  const pct = (a, b) => (b ? ((100 * a) / b).toFixed(1) + "%" : "n/a");
  console.log(`  balanceOf needed        ${stat.balanceOfNeeded}  (${per(stat.balanceOfNeeded)}/block)`);
  console.log(`  balanceOf derivable     ${stat.balanceOfDerived}  -> ${pct(stat.balanceOfDerived, stat.balanceOfNeeded)}`);
  console.log(`  eth_getBalance derivable ${stat.nativeBalanceDerived}  (${per(stat.nativeBalanceDerived)}/block) -> 100%`);
  console.log(`  eth_getCode derivable   ${stat.codeDerived} -> ${pct(stat.codeDerived, stat.codeNeeded)}`);
  if (OUT) {
    require("fs").writeFileSync(OUT, JSON.stringify([...sampleByKey.values()], null, 2));
    console.log(`\n  wrote ${sampleByKey.size} samples to ${OUT} for eth_call verification`);
  }
  process.exit(0);
});
