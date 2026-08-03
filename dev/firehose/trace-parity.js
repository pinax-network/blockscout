#!/usr/bin/env node

// Compares the sidecar's callTracer-shaped output with debug_traceBlockByNumber frame by frame.
// Unlike a frame-count comparison, this includes the derived trace address and every field that
// Blockscout imports from a call frame.

const assert = require("node:assert/strict");
const { flattenTrace } = require("./firehose-sidecar");

const RPC_URL = process.env.RPC_URL || process.env.ETHEREUM_JSONRPC_TRACE_URL;
const SIDECAR_URL = "http://127.0.0.1:8082/v1/blocks";

function quantity(value) {
  if (!value || value === "0x") return "0x0";
  return `0x${BigInt(value).toString(16)}`;
}

function data(value) {
  return (value || "0x").toLowerCase();
}

function canonicalFrames(result) {
  return flattenTrace(result).map((frame) => ({
    traceAddress: frame.traceAddress,
    type: frame.type.toUpperCase(),
    from: data(frame.from),
    to: frame.to ? data(frame.to) : undefined,
    value: quantity(frame.value),
    gas: quantity(frame.gas),
    gasUsed: quantity(frame.gasUsed),
    input: data(frame.input),
    output: data(frame.output),
    error: frame.error || null,
  }));
}

function traceEntries(entries) {
  return (entries || []).map((entry, index) => ({
    key: (entry.txHash || entry.transactionHash || `index:${index}`).toLowerCase(),
    frames: canonicalFrames(entry.result || entry),
  }));
}

function compareBlockTraces(rpcEntries, firehoseEntries, blockNumber) {
  const expected = traceEntries(rpcEntries);
  const actual = traceEntries(firehoseEntries);
  assert.deepEqual(actual, expected, `full callTracer mismatch at block ${blockNumber}`);
  return actual.reduce((count, transaction) => count + transaction.frames.length, 0);
}

async function postJson(url, body) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const json = await response.json();
  if (!response.ok) throw new Error(`${url} returned ${response.status}: ${JSON.stringify(json)}`);
  return json;
}

async function rpcTrace(blockNumber) {
  const response = await postJson(RPC_URL, {
    jsonrpc: "2.0",
    id: blockNumber,
    method: "debug_traceBlockByNumber",
    params: [quantity(blockNumber), { tracer: "callTracer" }],
  });
  if (response.error) throw new Error(`RPC block ${blockNumber}: ${JSON.stringify(response.error)}`);
  return response.result;
}

async function main() {
  const start = Number(process.env.START_BLOCK);
  const end = Number(process.env.END_BLOCK || process.env.START_BLOCK);
  if (!RPC_URL || !Number.isInteger(start) || !Number.isInteger(end) || start > end) {
    throw new Error(
      "Set RPC_URL (or ETHEREUM_JSONRPC_TRACE_URL), START_BLOCK and optional END_BLOCK"
    );
  }

  const sidecar = await postJson(SIDECAR_URL, { start_block: start, end_block: end });
  const blocks = new Map((sidecar.blocks || []).map((block) => [Number(block.number), block]));
  let frames = 0;

  for (let blockNumber = start; blockNumber <= end; blockNumber++) {
    const firehose = blocks.get(blockNumber);
    if (!firehose) throw new Error(`sidecar omitted block ${blockNumber}`);
    frames += compareBlockTraces(await rpcTrace(blockNumber), firehose.traces, blockNumber);
  }

  console.log(`full trace parity: ${end - start + 1} blocks, ${frames} frames, 0 mismatches`);
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error.stack || error.message);
    process.exitCode = 1;
  });
}

module.exports = { canonicalFrames, compareBlockTraces };
