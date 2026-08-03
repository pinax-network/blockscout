#!/usr/bin/env node
//
// Firehose-backed sidecar for Blockscout's EthereumJSONRPC.Firehose.
//
// Streams sf.ethereum.type.v2.Block ("extended" blocks) over gRPC and reshapes each one into the
// three JSON-RPC payloads Blockscout's parsers already understand - eth_getBlockByNumber,
// eth_getBlockReceipts, and debug_traceBlockByNumber(callTracer) - so one Firehose block replaces
// three round trips to an archive node.
//
//   POST /v1/blocks  {"start_block": 1, "end_block": 10}
//   -> {"blocks": [{"number", "block", "receipts", "traces"}, ...]}
//
// Usage - see .env.example for the full set:
//   FIREHOSE_ENDPOINT=<host>:443 FIREHOSE_API_KEY=<key> PORT=8082 node firehose-sidecar.js

const http = require("http");
const path = require("path");
const fs = require("fs");
const cluster = require("cluster");
const os = require("os");
const grpc = require("@grpc/grpc-js");
const protoLoader = require("@grpc/proto-loader");
const protobuf = require("protobufjs");

// Load a .env sitting next to this file, if present, without pulling in a dependency. Real
// environment variables always win, so the file is only a convenience for local runs.
(function loadDotEnv() {
  const envPath = path.join(__dirname, ".env");
  if (!fs.existsSync(envPath)) return;
  for (const line of fs.readFileSync(envPath, "utf8").split("\n")) {
    const m = line.match(/^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)\s*=\s*(.*)\s*$/i);
    if (!m) continue;
    const key = m[1];
    const value = m[2].replace(/^['"]|['"]$/g, "");
    if (!(key in process.env)) process.env[key] = value;
  }
})();

const ENDPOINT = process.env.FIREHOSE_ENDPOINT || "localhost:10015";
const PORT = parseInt(process.env.PORT || "8081", 10);
const PLAINTEXT = process.env.FIREHOSE_PLAINTEXT === "true";

// Firehose providers authenticate in one of two ways. Pinax and StreamingFast's hosted endpoints
// take a long-lived key in `x-api-key`; deployments fronted by StreamingFast's auth service take a
// short-lived JWT in `authorization: bearer <token>`. Set whichever your provider issues.
const API_KEY = process.env.FIREHOSE_API_KEY || process.env.PINAX_KEY || "";
const BEARER_TOKEN = process.env.FIREHOSE_BEARER_TOKEN || "";

const PROTO_OPTS = {
  keepCase: false,
  longs: String,
  enums: String,
  defaults: true,
  oneofs: true,
  includeDirs: [path.join(__dirname, "proto")],
};

const firehosePkg = grpc.loadPackageDefinition(
  protoLoader.loadSync("sf/firehose/v2/firehose.proto", PROTO_OPTS)
);
// The Any inside Response.block is decoded separately, against the Ethereum block type - it lives
// in a different Buf module (streamingfast/firehose-ethereum) than the Stream service
// (streamingfast/firehose). protobufjs is used here rather than proto-loader because only it
// hands back a message class with a usable `decode`.
const ethRoot = new protobuf.Root();
ethRoot.resolvePath = (_origin, target) =>
  target.startsWith("google/")
    ? protobuf.util.path.resolve(path.join(__dirname, "node_modules/protobufjs/"), target)
    : path.join(__dirname, "proto", target);
ethRoot.loadSync("sf/ethereum/type/v2/type.proto", { keepCase: false });
const EthBlock = ethRoot.lookupType("sf.ethereum.type.v2.Block");

function makeClient() {
  const creds = PLAINTEXT
    ? grpc.credentials.createInsecure()
    : grpc.credentials.createSsl();
  return new firehosePkg.sf.firehose.v2.Stream(ENDPOINT, creds, {
    "grpc.max_receive_message_length": 50 * 1024 * 1024,
    "grpc.keepalive_time_ms": 30000,
  });
}

const client = makeClient();

function metadata() {
  const md = new grpc.Metadata();
  if (API_KEY) md.set("x-api-key", API_KEY);
  if (BEARER_TOKEN) md.set("authorization", `bearer ${BEARER_TOKEN}`);
  return md;
}

// ---------------------------------------------------------------- conversion

const EMPTY = "0x";
// data fields: "0x" is a valid empty value
const hex = (b) => (b && b.length ? "0x" + Buffer.from(b).toString("hex") : EMPTY);
const addr = (b) => (b && b.length ? "0x" + Buffer.from(b).toString("hex") : null);
const qty = (n) => "0x" + BigInt(n || 0).toString(16);
// quantity fields carried as bytes (v/r/s): Blockscout runs these through
// quantity_to_integer/1, which rejects a bare "0x", so empty has to become "0x0"
const qtyBytes = (b) => (b && b.length ? "0x" + BigInt("0x" + Buffer.from(b).toString("hex")).toString(16) : "0x0");
// fixed-width data fields, e.g. the block's 8-byte nonce
const hexPadded = (n, bytes) => "0x" + BigInt(n || 0).toString(16).padStart(bytes * 2, "0");

// BigInt messages carry a big-endian two's complement byte string.
function bigIntQty(msg) {
  if (!msg) return "0x0";
  const b = msg.bytes;
  if (!b || !b.length) return "0x0";
  return "0x" + (BigInt("0x" + Buffer.from(b).toString("hex"))).toString(16);
}

function timestampSeconds(ts) {
  if (!ts) return 0;
  if (typeof ts === "string") return Math.floor(new Date(ts).getTime() / 1000);
  return Number(ts.seconds || 0);
}

// Firehose collapses CREATE and CREATE2 into a single CALL_TYPE; there is no flag distinguishing
// them, so a create2 shows up as "CREATE" and Blockscout records it as :create rather than
// :create2. Everything else maps one-to-one onto geth's callTracer vocabulary.
const CALL_TYPE = {
  CALL: "CALL",
  CALLCODE: "CALLCODE",
  DELEGATE: "DELEGATECALL",
  STATIC: "STATICCALL",
  CREATE: "CREATE",
  UNSPECIFIED: "CALL",
};

// Firehose flags a self-destructing contract with `suicide: true` on the call that created or
// entered it. A node's callTracer instead emits a *separate* SELFDESTRUCT frame nested inside that
// call, so one Firehose call corresponds to two tracer frames and has to be expanded.
//
// `from` and `value` come off the REASON_SUICIDE_WITHDRAW balance change. The beneficiary is only
// recoverable when the balance actually moved (REASON_SUICIDE_REFUND); a zero-value selfdestruct
// records no refund, so `to` is omitted in that case.
function selfdestructFrame(call) {
  const withdraw = (call.balanceChanges || []).find((b) => b.reason === "REASON_SUICIDE_WITHDRAW");
  const refund = (call.balanceChanges || []).find((b) => b.reason === "REASON_SUICIDE_REFUND");

  const frame = {
    type: "SELFDESTRUCT",
    from: addr(call.address) || EMPTY,
    value: withdraw ? bigIntQty(withdraw.oldValue) : "0x0",
    gas: "0x0",
    gasUsed: "0x0",
  };
  const beneficiary = refund && addr(refund.address);
  if (beneficiary) frame.to = beneficiary;
  return frame;
}

function callFrame(call) {
  const frame = {
    type: CALL_TYPE[call.callType] || "CALL",
    from: addr(call.caller) || EMPTY,
    to: addr(call.address) || undefined,
    value: bigIntQty(call.value),
    gas: qty(call.gasLimit),
    gasUsed: qty(call.gasConsumed),
    input: hex(call.input),
    output: hex(call.returnData),
  };

  if (call.statusFailed || call.statusReverted) {
    frame.error = call.failureReason || (call.statusReverted ? "execution reverted" : "error");
  }
  if (frame.output === EMPTY) delete frame.output;
  if (frame.to === undefined) delete frame.to;

  return frame;
}

// Firehose emits a transaction's calls as a flat list carrying index/parentIndex; callTracer wants
// them nested. Rebuild the tree in one pass. Index 0 means "no parent" (proto3 default), so the
// root is the call whose parentIndex is absent or 0.
function buildCallTree(calls) {
  if (!calls || !calls.length) return null;

  const byIndex = new Map();
  for (const call of calls) byIndex.set(Number(call.index), { call, frame: callFrame(call) });

  let root = null;
  for (const { call, frame } of byIndex.values()) {
    const parentIndex = Number(call.parentIndex || 0);
    const parent = parentIndex ? byIndex.get(parentIndex) : null;

    if (!parent) {
      // first rootless call wins; any others are appended to it so nothing is silently dropped
      if (!root) root = frame;
      else (root.calls = root.calls || []).push(frame);
    } else {
      (parent.frame.calls = parent.frame.calls || []).push(frame);
    }
  }

  // Expand `suicide` into the extra SELFDESTRUCT frame a tracer would emit. Done after the tree is
  // assembled so the synthetic frame lands last among its siblings, which is where a node puts it.
  for (const { call, frame } of byIndex.values()) {
    if (call.suicide) (frame.calls = frame.calls || []).push(selfdestructFrame(call));
  }

  return root;
}

const FAILED_TRANSACTION_BALANCE_REASONS = new Set([
  "REASON_GAS_BUY",
  "REASON_GAS_REFUND",
  "REASON_REWARD_TRANSACTION_FEE",
]);

// Final native balance per account in the block. balance_changes are recorded state - the node
// wrote these values down - but the extended model also retains state changes from reverted calls.
// Successful transactions contribute only non-reverted calls. For failed transactions, Firehose's
// contract says only the root call's gas buy/refund and transaction fee changes survive. Ordinals
// give the total order, so the highest committed change per address is the end-of-block value.
function coinBalances(block) {
  const final = new Map();
  const take = (bc) => {
    const address = addr(bc.address);
    if (!address) return;
    const ordinal = Number(bc.ordinal || 0);
    const prev = final.get(address);
    if (!prev || ordinal > prev.ordinal) final.set(address, { ordinal, value: bigIntQty(bc.newValue) });
  };

  for (const bc of block.balanceChanges || []) take(bc); // block-level, e.g. rewards
  for (const call of block.systemCalls || []) {
    if (!call.stateReverted) for (const bc of call.balanceChanges || []) take(bc);
  }

  for (const transaction of block.transactionTraces || []) {
    const calls = transaction.calls || [];

    if (transaction.status === "SUCCEEDED") {
      for (const call of calls) {
        if (!call.stateReverted) for (const bc of call.balanceChanges || []) take(bc);
      }
    } else if (transaction.status === "FAILED" || transaction.status === "REVERTED") {
      const rootCall = calls.find((call) => Number(call.parentIndex || 0) === 0);
      for (const bc of (rootCall && rootCall.balanceChanges) || []) {
        if (FAILED_TRANSACTION_BALANCE_REASONS.has(bc.reason)) take(bc);
      }
    }
  }

  return [...final].map(([address, v]) => ({ address, value: v.value }));
}

function convertBlock(block) {
  const header = block.header || {};
  const number = Number(block.number);
  const blockHash = hex(block.hash);
  const blockNumberHex = qty(number);
  const traces = block.transactionTraces || [];

  const transactions = traces.map((t) => ({
    hash: hex(t.hash),
    nonce: qty(t.nonce),
    blockHash,
    blockNumber: blockNumberHex,
    transactionIndex: qty(t.index),
    from: addr(t.from) || EMPTY,
    to: addr(t.to),
    value: bigIntQty(t.value),
    gas: qty(t.gasLimit),
    gasPrice: bigIntQty(t.gasPrice),
    maxFeePerGas: bigIntQty(t.maxFeePerGas),
    maxPriorityFeePerGas: bigIntQty(t.maxPriorityFeePerGas),
    input: hex(t.input),
    type: qty(typeNumber(t.type)),
    v: qtyBytes(t.v),
    r: qtyBytes(t.r),
    s: qtyBytes(t.s),
  }));

  const receipts = traces.map((t) => {
    const receipt = t.receipt || {};
    // A contract creation's address is only on the CREATE call, not on the receipt message.
    const created =
      addr(t.to) === null
        ? (t.calls || []).find((c) => c.callType === "CREATE" && Number(c.parentIndex || 0) === 0)
        : null;

    return {
      transactionHash: hex(t.hash),
      transactionIndex: qty(t.index),
      blockHash,
      blockNumber: blockNumberHex,
      from: addr(t.from) || EMPTY,
      to: addr(t.to),
      cumulativeGasUsed: qty(receipt.cumulativeGasUsed),
      gasUsed: qty(t.gasUsed),
      effectiveGasPrice: bigIntQty(t.gasPrice),
      contractAddress: created ? addr(created.address) : null,
      logsBloom: hex(receipt.logsBloom),
      // status lives on the trace, not the receipt
      status: t.status === "SUCCEEDED" ? "0x1" : "0x0",
      type: qty(typeNumber(t.type)),
      logs: (receipt.logs || []).map((log) => ({
        address: addr(log.address) || EMPTY,
        topics: (log.topics || []).map(hex),
        data: hex(log.data),
        // JSON-RPC logIndex is block-scoped; Firehose's `index` is transaction-scoped
        logIndex: qty(log.blockIndex),
        transactionHash: hex(t.hash),
        transactionIndex: qty(t.index),
        blockHash,
        blockNumber: blockNumberHex,
        removed: false,
      })),
    };
  });

  // Block-level system calls are not attached to any TransactionTrace, but a node's callTracer
  // reports them nested inside the chain's system transaction - on Arbitrum that is the ArbOS
  // internal transaction, always index 0. Without this they are silently missing: on Robinhood
  // that was 2 internal transactions per block, ~2.5% of the total.
  const systemFrame = buildCallTree(block.systemCalls);

  const callTraces = traces.map((t) => {
    const result = buildCallTree(t.calls);
    if (!result) throw new Error(`transaction ${hex(t.hash)} has no call trace`);
    if (systemFrame && isSystemTransaction(t)) {
      (result.calls = result.calls || []).push(systemFrame);
    }
    return { txHash: hex(t.hash), result };
  });

  return {
    number,
    block: {
      hash: blockHash,
      number: blockNumberHex,
      parentHash: hex(header.parentHash),
      sha3Uncles: hex(header.uncleHash),
      miner: addr(header.coinbase) || EMPTY,
      stateRoot: hex(header.stateRoot),
      transactionsRoot: hex(header.transactionsRoot),
      receiptsRoot: hex(header.receiptRoot),
      logsBloom: hex(header.logsBloom),
      difficulty: bigIntQty(header.difficulty),
      totalDifficulty: bigIntQty(header.totalDifficulty),
      gasLimit: qty(header.gasLimit),
      gasUsed: qty(header.gasUsed),
      timestamp: qty(timestampSeconds(header.timestamp)),
      extraData: hex(header.extraData),
      mixHash: hex(header.mixHash),
      nonce: hexPadded(header.nonce, 8),
      baseFeePerGas: header.baseFeePerGas ? bigIntQty(header.baseFeePerGas) : undefined,
      size: qty(block.size),
      uncles: [],
      withdrawals: (block.withdrawals || []).map((w) => ({
        index: qty(w.index),
        validatorIndex: qty(w.validatorIndex),
        address: addr(w.address) || EMPTY,
        amount: qty(w.amount),
      })),
      transactions,
    },
    receipts,
    traces: callTraces,
    balanceChanges: coinBalances(block),
  };
}

// The chain's own bookkeeping transaction, which is where a node's tracer hangs the block's
// system calls. On Arbitrum it is the ArbOS internal transaction at index 0.
function isSystemTransaction(t) {
  return Number(t.index || 0) === 0 && t.type === "TRX_TYPE_ARBITRUM_INTERNAL";
}

function typeNumber(type) {
  switch (type) {
    case "TRX_TYPE_LEGACY":
      return 0;
    case "TRX_TYPE_ACCESS_LIST":
      return 1;
    case "TRX_TYPE_DYNAMIC_FEE":
      return 2;
    case "TRX_TYPE_BLOB":
      return 3;
    case "TRX_TYPE_ARBITRUM_DEPOSIT":
      return 100;
    case "TRX_TYPE_ARBITRUM_UNSIGNED":
      return 101;
    case "TRX_TYPE_ARBITRUM_CONTRACT":
      return 102;
    case "TRX_TYPE_ARBITRUM_RETRY":
      return 104;
    case "TRX_TYPE_ARBITRUM_SUBMIT_RETRYABLE":
      return 105;
    case "TRX_TYPE_ARBITRUM_INTERNAL":
      return 106;
    case "TRX_TYPE_ARBITRUM_LEGACY":
      return 120;
    default:
      return 0;
  }
}

// ------------------------------------------------------------------ streaming

function fetchRange(startBlock, endBlock) {
  return new Promise((resolve, reject) => {
    const out = [];
    // proto-loader is loaded with keepCase:false, so request fields are camelCase here
    const stream = client.Blocks(
      {
        startBlockNum: startBlock,
        stopBlockNum: endBlock, // inclusive
        finalBlocksOnly: true,
      },
      metadata(),
      { deadline: Date.now() + 120000 }
    );

    stream.on("data", (response) => {
      try {
        // Response.block is a google.protobuf.Any wrapping sf.ethereum.type.v2.Block.
        // toObject with enums-as-strings gives the same shape the converter reads.
        const block = EthBlock.toObject(EthBlock.decode(response.block.value), {
          enums: String,
          longs: String,
          bytes: Buffer,
          defaults: true,
        });
        out.push(convertBlock(block));
      } catch (e) {
        stream.cancel();
        reject(new Error(`decode failed: ${e.message}`));
      }
    });
    stream.on("error", (e) => {
      if (e.code === grpc.status.CANCELLED) return;
      if (e.code === grpc.status.UNAUTHENTICATED || e.code === grpc.status.PERMISSION_DENIED) {
        return reject(
          new Error(
            `firehose auth rejected (${e.details || e.message}). ` +
              `Set FIREHOSE_API_KEY (or FIREHOSE_BEARER_TOKEN) - see dev/firehose/.env.example`
          )
        );
      }
      reject(new Error(`firehose stream: ${e.details || e.message}`));
    });
    stream.on("end", () => {
      try {
        validateFetchedRange(out, startBlock, endBlock);
        resolve(out);
      } catch (e) {
        reject(e);
      }
    });
  });
}

function validateFetchedRange(blocks, startBlock, endBlock) {
  const expected = endBlock - startBlock + 1;
  const counts = new Map();
  for (const block of blocks) counts.set(block.number, (counts.get(block.number) || 0) + 1);

  const missing = [];
  for (let number = startBlock; number <= endBlock; number++) {
    if (!counts.has(number)) missing.push(number);
  }

  const duplicates = [...counts]
    .filter(([, count]) => count > 1)
    .map(([number]) => number)
    .sort((a, b) => a - b);
  const unexpected = [...counts.keys()]
    .filter((number) => number < startBlock || number > endBlock)
    .sort((a, b) => a - b);

  if (blocks.length !== expected || missing.length || duplicates.length || unexpected.length) {
    throw new Error(
      `incomplete firehose range ${startBlock}..${endBlock}: ` +
        `missing=${JSON.stringify(missing)} duplicates=${JSON.stringify(duplicates)} ` +
        `unexpected=${JSON.stringify(unexpected)}`
    );
  }
}

// ---------------------------------------------------------------- http server

const server = http.createServer(async (req, res) => {
  const send = (code, obj) => {
    const body = JSON.stringify(obj);
    res.writeHead(code, {
      "content-type": "application/json",
      "content-length": Buffer.byteLength(body),
    });
    res.end(body);
  };

  if (req.method === "GET" && req.url === "/health") {
    return send(200, {
      ok: true,
      endpoint: ENDPOINT,
      source: "firehose",
      auth: API_KEY ? "api-key" : BEARER_TOKEN ? "bearer" : "none",
    });
  }
  if (req.method !== "POST") return send(405, { error: "method not allowed" });

  let raw = "";
  for await (const chunk of req) raw += chunk;

  let start, end;
  try {
    ({ start_block: start, end_block: end } = JSON.parse(raw));
    if (!Number.isInteger(start) || !Number.isInteger(end) || start > end) {
      throw new Error("start_block/end_block must be integers with start_block <= end_block");
    }
  } catch (e) {
    return send(400, { error: String(e.message || e) });
  }

  const started = Date.now();
  try {
    const blocks = await fetchRange(start, end);
    const txs = blocks.reduce((a, b) => a + b.receipts.length, 0);
    const itxs = blocks.reduce(
      (a, b) => a + b.traces.reduce((n, t) => n + countFrames(t.result), 0),
      0
    );
    const bals = blocks.reduce((a, b) => a + b.balanceChanges.length, 0);
    console.log(
      `[firehose] ${start}..${end} -> ${blocks.length} blocks, ${txs} txs, ${itxs} calls, ` +
        `${bals} balances in ${Date.now() - started}ms`
    );
    send(200, { blocks });
  } catch (e) {
    console.error(`[firehose] ${start}..${end} failed: ${e.message}`);
    send(502, { error: String(e.message || e) });
  }
});

function countFrames(frame) {
  if (!frame) return 0;
  return 1 + (frame.calls || []).reduce((a, c) => a + countFrames(c), 0);
}

// Decoding protobuf and re-encoding it as JSON is CPU-bound, and it pins one core: with a single
// process the sidecar tops out around 16 blocks/s no matter how many ranges Blockscout requests
// concurrently, which makes it - not Firehose - the bottleneck. Fork one worker per core and let
// the kernel spread the accepted connections across them.
const WORKERS = parseInt(process.env.FIREHOSE_WORKERS || String(Math.max(1, os.cpus().length - 2)), 10);

function start() {
  if (cluster.isPrimary && !API_KEY && !BEARER_TOKEN) {
    console.warn(
      `[firehose] WARNING: neither FIREHOSE_API_KEY nor FIREHOSE_BEARER_TOKEN is set - requests to ` +
        `${ENDPOINT} will be sent unauthenticated and will most likely be rejected. ` +
        `See dev/firehose/.env.example`
    );
  }

  if (cluster.isPrimary && WORKERS > 1) {
    console.log(`[firehose] primary ${process.pid}: forking ${WORKERS} workers, upstream ${ENDPOINT}`);
    for (let i = 0; i < WORKERS; i++) cluster.fork();
    cluster.on("exit", (worker, code) => {
      if (code !== 0) {
        console.error(`[firehose] worker ${worker.process.pid} died (${code}), restarting`);
        cluster.fork();
      }
    });
  } else {
    server.listen(PORT, () =>
      console.log(`[firehose] worker ${process.pid} listening on :${PORT}, streaming from ${ENDPOINT}`)
    );
  }
}

if (require.main === module) start();

module.exports = { coinBalances, convertBlock, start, validateFetchedRange };
