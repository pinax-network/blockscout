#!/usr/bin/env bash
#
# Re-syncs the checked-in protos from the Buf Schema Registry, which is the authoritative source.
#
# The two schemas live in *different* Buf modules:
#   - streamingfast/firehose           -> sf/firehose/v2/firehose.proto  (the Stream service)
#   - streamingfast/firehose-ethereum  -> sf/ethereum/type/v2/type.proto (the block type)
#
# Response.block is a google.protobuf.Any that has to be unpacked against the second one.
#
# Requires the buf CLI: https://buf.build/docs/installation
set -euo pipefail

cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

buf export buf.build/streamingfast/firehose --output "$TMP/firehose"
buf export buf.build/streamingfast/firehose-ethereum --output "$TMP/ethereum"

mkdir -p proto/sf/firehose/v2 proto/sf/ethereum/type/v2
cp "$TMP/firehose/sf/firehose/v2/firehose.proto" proto/sf/firehose/v2/firehose.proto
cp "$TMP/ethereum/sf/ethereum/type/v2/type.proto" proto/sf/ethereum/type/v2/type.proto

echo "synced:"
git -C ../.. status --short dev/firehose/proto || true
