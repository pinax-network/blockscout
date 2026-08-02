#!/usr/bin/env node
//
// Reference implementation of the Firehose sidecar contract consumed by
// EthereumJSONRPC.Firehose (apps/ethereum_jsonrpc/lib/ethereum_jsonrpc/firehose.ex).
//
// A production sidecar reads Firehose extended blocks (gRPC stream or merged block files) and
// reshapes them into this payload. This one is backed by a plain JSON-RPC node instead, so the
// Blockscout side of the integration can be exercised end to end without Firehose infrastructure.
// The response shape is byte-for-byte what a real sidecar must emit.
//
//   POST /v1/blocks  {"start_block": 1, "end_block": 10}
//   -> {"blocks": [{"number", "block", "receipts", "traces"}, ...]}
//
// Usage: RPC_URL=http://127.0.0.1:8545 PORT=8081 node firehose-sidecar.js

const http = require("http");

const RPC_URL = process.env.RPC_URL || "http://127.0.0.1:8545";
const PORT = parseInt(process.env.PORT || "8081", 10);

let rpcId = 0;

async function rpcBatch(calls) {
  if (calls.length === 0) return [];
  const payload = calls.map((c) => ({
    jsonrpc: "2.0",
    id: ++rpcId,
    method: c.method,
    params: c.params,
  }));

  const res = await fetch(RPC_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
  if (!res.ok) throw new Error(`upstream ${res.status}: ${await res.text()}`);

  const body = await res.json();
  const byId = new Map((Array.isArray(body) ? body : [body]).map((r) => [r.id, r]));
  return payload.map((p) => {
    const r = byId.get(p.id);
    if (!r) throw new Error(`no response for id ${p.id} (${p.method})`);
    if (r.error) throw new Error(`${p.method} failed: ${JSON.stringify(r.error)}`);
    return r.result;
  });
}

const hex = (n) => "0x" + n.toString(16);

// Normalizes debug_traceBlockByNumber output to the [{txHash, result}] shape the contract
// requires. Geth returns exactly that; some clients return a bare array of frames, in which case
// the transaction hashes are taken from the block in order.
function normalizeTraces(raw, block) {
  if (!Array.isArray(raw)) return [];
  return raw.map((entry, i) => {
    if (entry && typeof entry === "object" && "result" in entry) {
      return { txHash: entry.txHash || block.transactions[i]?.hash, result: entry.result };
    }
    return { txHash: block.transactions[i]?.hash, result: entry };
  });
}

async function fetchBlock(number) {
  const [block] = await rpcBatch([
    { method: "eth_getBlockByNumber", params: [hex(number), true] },
  ]);

  if (!block) return { number, block: null, receipts: [], traces: [] };

  const txCount = (block.transactions || []).length;
  let receipts = [];
  let traces = [];

  if (txCount > 0) {
    // eth_getBlockReceipts where available, per-transaction receipts otherwise. Every
    // transaction must get a receipt: Receipts.put/2 looks them up with Map.fetch!/2.
    try {
      const [blockReceipts] = await rpcBatch([
        { method: "eth_getBlockReceipts", params: [hex(number)] },
      ]);
      receipts = blockReceipts || [];
    } catch {
      receipts = await rpcBatch(
        block.transactions.map((t) => ({
          method: "eth_getTransactionReceipt",
          params: [t.hash],
        }))
      );
    }

    if (receipts.length !== txCount) {
      throw new Error(`block ${number}: ${receipts.length} receipts for ${txCount} transactions`);
    }

    const [rawTraces] = await rpcBatch([
      {
        method: "debug_traceBlockByNumber",
        params: [hex(number), { tracer: "callTracer" }],
      },
    ]);
    traces = normalizeTraces(rawTraces, block);
  }

  return { number, block, receipts, traces };
}

const server = http.createServer(async (req, res) => {
  const send = (code, obj) => {
    const body = JSON.stringify(obj);
    res.writeHead(code, { "content-type": "application/json", "content-length": Buffer.byteLength(body) });
    res.end(body);
  };

  if (req.method === "GET" && req.url === "/health") return send(200, { ok: true, rpc: RPC_URL });
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
    const blocks = [];
    for (let n = start; n <= end; n++) blocks.push(await fetchBlock(n));
    console.log(
      `[sidecar] ${start}..${end} (${end - start + 1} blocks, ` +
        `${blocks.reduce((a, b) => a + b.receipts.length, 0)} txs) in ${Date.now() - started}ms`
    );
    send(200, { blocks });
  } catch (e) {
    console.error(`[sidecar] ${start}..${end} failed:`, e.message);
    send(502, { error: String(e.message || e) });
  }
});

server.listen(PORT, () => console.log(`[sidecar] listening on :${PORT}, upstream ${RPC_URL}`));
