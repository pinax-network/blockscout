const assert = require("node:assert/strict");
const test = require("node:test");

const {
  chainFamilyForChainType,
  coinBalances,
  convertBlock,
  flattenTrace,
  server,
  validateBlockFamily,
  validateFetchedRange,
} = require("./firehose-sidecar");

test("chain family reuses Blockscout's native chain type", () => {
  assert.equal(chainFamilyForChainType(undefined), "ethereum");
  assert.equal(chainFamilyForChainType("default"), "ethereum");
  assert.equal(chainFamilyForChainType("ethereum"), "ethereum");
  assert.equal(chainFamilyForChainType("arbitrum"), "arbitrum");
  assert.equal(chainFamilyForChainType("optimism"), "optimism");
});
const { compareBlockTraces } = require("./trace-parity");

const address = (lastByte) => Buffer.from("00".repeat(19) + lastByte.toString(16).padStart(2, "0"), "hex");
const data = (lastByte, length = 32) =>
  Buffer.from("00".repeat(length - 1) + lastByte.toString(16).padStart(2, "0"), "hex");
const bigInt = (value) => {
  const raw = BigInt(value).toString(16);
  return { bytes: Buffer.from(raw.length % 2 ? `0${raw}` : raw, "hex") };
};
const balanceChange = (account, value, ordinal, reason = "REASON_TRANSFER") => ({
  address: account,
  newValue: bigInt(value),
  ordinal,
  reason,
});

function transactionTrace(type = "TRX_TYPE_LEGACY", overrides = {}) {
  return {
    type,
    hash: data(0x11),
    nonce: 3,
    index: 0,
    from: address(1),
    to: address(2),
    value: bigInt(5),
    gasLimit: 50_000,
    gasUsed: 30_000,
    gasPrice: bigInt(10),
    maxFeePerGas: bigInt(20),
    maxPriorityFeePerGas: bigInt(2),
    input: Buffer.from("1234", "hex"),
    v: data(1, 1),
    r: data(2),
    s: data(3),
    status: "SUCCEEDED",
    calls: [
      {
        index: 1,
        parentIndex: 0,
        callType: "CALL",
        caller: address(1),
        address: address(2),
        value: bigInt(5),
        gasLimit: 50_000,
        gasConsumed: 30_000,
        input: Buffer.from("1234", "hex"),
        returnData: Buffer.from("abcd", "hex"),
      },
    ],
    receipt: {
      cumulativeGasUsed: 30_000,
      logsBloom: Buffer.alloc(256),
      logs: [],
    },
    ...overrides,
  };
}

function firehoseBlock(trace = transactionTrace(), overrides = {}) {
  return {
    number: 100,
    hash: data(0x21),
    size: 1_000,
    header: {
      parentHash: data(0x20),
      uncleHash: data(0x22),
      coinbase: address(3),
      stateRoot: data(0x23),
      transactionsRoot: data(0x24),
      receiptRoot: data(0x25),
      logsBloom: Buffer.alloc(256),
      difficulty: bigInt(0),
      totalDifficulty: bigInt(0),
      gasLimit: 30_000_000,
      gasUsed: 30_000,
      timestamp: { seconds: "1" },
      extraData: Buffer.alloc(0),
      mixHash: data(0x26),
      nonce: 0,
      baseFeePerGas: bigInt(7),
    },
    transactionTraces: [trace],
    withdrawals: [],
    ...overrides,
  };
}

test("coinBalances ignores state changes from reverted calls", () => {
  const account = address(1);
  const balances = coinBalances({
    transactionTraces: [
      {
        status: "SUCCEEDED",
        calls: [
          { stateReverted: false, balanceChanges: [balanceChange(account, 10, 1)] },
          { stateReverted: true, balanceChanges: [balanceChange(account, 99, 2)] },
        ],
      },
    ],
  });

  assert.deepEqual(balances, [{ address: "0x" + "00".repeat(19) + "01", value: "0xa" }]);
});

test("coinBalances keeps only persistent root changes from failed transactions", () => {
  const sender = address(2);
  const recipient = address(3);
  const balances = coinBalances({
    transactionTraces: [
      {
        status: "REVERTED",
        calls: [
          {
            parentIndex: 0,
            balanceChanges: [
              balanceChange(sender, 8, 1, "REASON_GAS_BUY"),
              balanceChange(recipient, 100, 2, "REASON_TRANSFER"),
              balanceChange(sender, 9, 3, "REASON_GAS_REFUND"),
            ],
          },
          {
            parentIndex: 1,
            balanceChanges: [balanceChange(recipient, 200, 4, "REASON_REWARD_TRANSACTION_FEE")],
          },
        ],
      },
    ],
  });

  assert.deepEqual(balances, [{ address: "0x" + "00".repeat(19) + "02", value: "0x9" }]);
});

test("validateFetchedRange rejects incomplete, duplicate, and unexpected responses", () => {
  assert.doesNotThrow(() => validateFetchedRange([{ number: 10 }, { number: 11 }], 10, 11));
  assert.throws(
    () => validateFetchedRange([{ number: 9 }, { number: 10 }, { number: 10 }], 10, 11),
    /missing=\[11\].*duplicates=\[10\].*unexpected=\[9\]/
  );
});

test("HTTP errors do not expose caught exception details", async (context) => {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  context.after(() => new Promise((resolve) => server.close(resolve)));

  const { port } = server.address();
  const invalidResponse = await fetch(`http://127.0.0.1:${port}/v1/blocks`, {
    method: "POST",
    body: "{",
  });

  assert.equal(invalidResponse.status, 400);
  assert.deepEqual(await invalidResponse.json(), { error: "invalid range request" });

  const upstreamResponse = await fetch(`http://127.0.0.1:${port}/v1/blocks`, {
    method: "POST",
    body: JSON.stringify({ start_block: 10, end_block: 10 }),
  });

  assert.equal(upstreamResponse.status, 502);
  assert.deepEqual(await upstreamResponse.json(), { error: "firehose range fetch failed" });
});

test("convertBlock preserves Cancun and Prague block, blob transaction, and receipt fields", () => {
  const blobHash = data(0x31);
  const trace = transactionTrace("TRX_TYPE_BLOB", {
    accessList: [{ address: address(4), storageKeys: [data(0x32)] }],
    blobGasFeeCap: bigInt(1_000),
    blobHashes: [blobHash],
    receipt: {
      cumulativeGasUsed: 30_000,
      logsBloom: Buffer.alloc(256),
      logs: [],
      blobGasUsed: 131_072,
      blobGasPrice: bigInt(25),
    },
  });
  const block = firehoseBlock(trace);
  block.header.withdrawalsRoot = data(0x41);
  block.header.blobGasUsed = 131_072;
  block.header.excessBlobGas = 262_144;
  block.header.parentBeaconRoot = data(0x42);
  block.header.requestsHash = data(0x43);

  const converted = convertBlock(block);
  const transaction = converted.block.transactions[0];
  const receipt = converted.receipts[0];

  assert.equal(converted.block.withdrawalsRoot, `0x${data(0x41).toString("hex")}`);
  assert.equal(converted.block.blobGasUsed, "0x20000");
  assert.equal(converted.block.excessBlobGas, "0x40000");
  assert.equal(converted.block.parentBeaconBlockRoot, `0x${data(0x42).toString("hex")}`);
  assert.equal(converted.block.requestsHash, `0x${data(0x43).toString("hex")}`);
  assert.equal(transaction.type, "0x3");
  assert.equal(transaction.maxFeePerBlobGas, "0x3e8");
  assert.deepEqual(transaction.blobVersionedHashes, [`0x${blobHash.toString("hex")}`]);
  assert.deepEqual(transaction.accessList, [
    { address: `0x${address(4).toString("hex")}`, storageKeys: [`0x${data(0x32).toString("hex")}`] },
  ]);
  assert.equal(receipt.blobGasUsed, "0x20000");
  assert.equal(receipt.blobGasPrice, "0x19");
});

test("convertBlock emits EIP-7702 transactions and authorization tuples", () => {
  const trace = transactionTrace("TRX_TYPE_SET_CODE", {
    accessList: [],
    setCodeAuthorizations: [
      {
        chainId: data(1, 1),
        address: address(5),
        nonce: 9,
        v: 1,
        r: data(6),
        s: data(7),
        discarded: false,
      },
    ],
  });

  const transaction = convertBlock(firehoseBlock(trace)).block.transactions[0];

  assert.equal(transaction.type, "0x4");
  assert.deepEqual(transaction.authorizationList, [
    {
      chainId: "0x1",
      address: `0x${address(5).toString("hex")}`,
      nonce: "0x9",
      yParity: "0x1",
      r: "0x6",
      s: "0x7",
    },
  ]);
});

test("convertBlock maps Optimism and Polygon transaction types without treating them as legacy", () => {
  assert.equal(
    convertBlock(firehoseBlock(transactionTrace("TRX_TYPE_OPTIMISM_DEPOSIT"))).block.transactions[0].type,
    "0x7e"
  );
  assert.equal(
    convertBlock(firehoseBlock(transactionTrace("TRX_TYPE_POLYGON_STATE_SYNC"))).block.transactions[0].type,
    "0xc8"
  );
});

test("validateBlockFamily keeps unverified chain families fail-closed", () => {
  assert.doesNotThrow(() => validateBlockFamily(firehoseBlock(), "ethereum"));
  assert.doesNotThrow(() =>
    validateBlockFamily(firehoseBlock(transactionTrace("TRX_TYPE_ARBITRUM_INTERNAL")), "arbitrum")
  );
  assert.throws(
    () => validateBlockFamily(firehoseBlock(transactionTrace("TRX_TYPE_ARBITRUM_INTERNAL")), "ethereum"),
    /not supported for CHAIN_TYPE=ethereum/
  );
  assert.throws(
    () => validateBlockFamily(firehoseBlock(transactionTrace("TRX_TYPE_OPTIMISM_DEPOSIT")), "optimism"),
    /unsupported CHAIN_TYPE optimism/
  );
});

test("system calls attach to an Arbitrum internal transaction by type, not position", () => {
  const systemCall = {
    index: 1,
    parentIndex: 0,
    callType: "CALL",
    caller: address(8),
    address: address(9),
    value: bigInt(0),
    gasLimit: 1_000,
    gasConsumed: 500,
  };
  const arbitrumTrace = transactionTrace("TRX_TYPE_ARBITRUM_INTERNAL", { index: 7 });
  const ethereumTrace = transactionTrace("TRX_TYPE_LEGACY");

  const arbitrum = convertBlock(firehoseBlock(arbitrumTrace, { systemCalls: [systemCall] }));
  const ethereum = convertBlock(firehoseBlock(ethereumTrace, { systemCalls: [systemCall] }));

  assert.equal(arbitrum.traces[0].result.calls.length, 1);
  assert.equal(arbitrum.traces[0].result.calls[0].from, `0x${address(8).toString("hex")}`);
  assert.equal(ethereum.traces[0].result.calls, undefined);
});

test("flattenTrace compares full frames at their derived trace addresses", () => {
  const root = {
    type: "CALL",
    from: "0x01",
    to: "0x02",
    value: "0x3",
    gas: "0x4",
    gasUsed: "0x5",
    input: "0x06",
    output: "0x07",
    calls: [
      {
        type: "DELEGATECALL",
        from: "0x02",
        to: "0x03",
        value: "0x0",
        gas: "0x8",
        gasUsed: "0x9",
        input: "0x0a",
        error: "execution reverted",
      },
    ],
  };

  assert.deepEqual(flattenTrace(root), [
    {
      traceAddress: [],
      type: "CALL",
      from: "0x01",
      to: "0x02",
      value: "0x3",
      gas: "0x4",
      gasUsed: "0x5",
      input: "0x06",
      output: "0x07",
      error: null,
    },
    {
      traceAddress: [0],
      type: "DELEGATECALL",
      from: "0x02",
      to: "0x03",
      value: "0x0",
      gas: "0x8",
      gasUsed: "0x9",
      input: "0x0a",
      output: "0x",
      error: "execution reverted",
    },
  ]);
});

test("compareBlockTraces rejects field drift even when frame counts match", () => {
  const expected = [
    {
      txHash: "0x01",
      result: {
        type: "CALL",
        from: "0x01",
        to: "0x02",
        value: "0x3",
        gas: "0x4",
        gasUsed: "0x5",
        input: "0x06",
        output: "0x07",
      },
    },
  ];
  const actual = structuredClone(expected);

  assert.equal(compareBlockTraces(expected, actual, 100), 1);
  actual[0].result.output = "0x08";
  assert.throws(() => compareBlockTraces(expected, actual, 100), /full callTracer mismatch at block 100/);
});

test("convertBlock rejects incomplete Ethereum typed data instead of importing defaults", () => {
  const incomplete = firehoseBlock(
    transactionTrace("TRX_TYPE_DYNAMIC_FEE", {
      maxFeePerGas: undefined,
      maxPriorityFeePerGas: undefined,
    })
  );

  assert.throws(
    () => convertBlock(incomplete, "ethereum"),
    /fee-market transaction .* is missing its max fee fields/
  );
  assert.throws(
    () => convertBlock(firehoseBlock(transactionTrace("TRX_TYPE_BLOB"))),
    /blob transaction .* is missing its blob fee cap or versioned hashes/
  );
  assert.throws(
    () => convertBlock(firehoseBlock(transactionTrace("TRX_TYPE_SET_CODE", { setCodeAuthorizations: [{}] }))),
    /authorization 0 is missing its delegate address/
  );
  assert.throws(
    () => convertBlock(firehoseBlock(transactionTrace("TRX_TYPE_FUTURE"))),
    /unsupported Firehose transaction type/
  );
});

test("convertBlock omits unavailable Arbitrum fee caps without inventing values", () => {
  const converted = convertBlock(
    firehoseBlock(
      transactionTrace("TRX_TYPE_DYNAMIC_FEE", {
        maxFeePerGas: undefined,
        maxPriorityFeePerGas: undefined,
      })
    ),
    "arbitrum"
  );
  const transaction = converted.block.transactions[0];

  assert.equal(transaction.gasPrice, "0xa");
  assert.equal(Object.hasOwn(transaction, "maxFeePerGas"), false);
  assert.equal(Object.hasOwn(transaction, "maxPriorityFeePerGas"), false);
});
