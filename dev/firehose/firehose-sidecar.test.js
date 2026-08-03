const assert = require("node:assert/strict");
const test = require("node:test");

const { coinBalances, validateFetchedRange } = require("./firehose-sidecar");

const address = (lastByte) => Buffer.from("00".repeat(19) + lastByte.toString(16).padStart(2, "0"), "hex");
const bigInt = (value) => ({ bytes: Buffer.from(BigInt(value).toString(16).padStart(2, "0"), "hex") });
const balanceChange = (account, value, ordinal, reason = "REASON_TRANSFER") => ({
  address: account,
  newValue: bigInt(value),
  ordinal,
  reason,
});

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
