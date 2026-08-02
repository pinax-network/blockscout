# Example environment for a local, indexer-only Blockscout run.
#
#   source dev/firehose/local-env.sh
#
# Set INDEXER_FIREHOSE_URL to route backfill through the Firehose connector; leave it unset for
# stock JSON-RPC behaviour. Nothing here is a real credential - override for your own environment.

export MIX_ENV=${MIX_ENV:-dev}

export DATABASE_URL="${DATABASE_URL:-postgresql://blockscout:blockscout@127.0.0.1:7432/blockscout}"
export REDIS_URL="${REDIS_URL:-redis://127.0.0.1:6379}"
export ACCOUNT_REDIS_URL="$REDIS_URL"
# dev-only placeholder; generate your own with `mix phx.gen.secret`
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(head -c 48 /dev/urandom | base64 | tr -d '\n')}"

# Archive node. Still required even with Firehose enabled: eth_call-backed fetchers (token
# metadata, balanceOf, contract reads) cannot be served from Firehose.
export ETHEREUM_JSONRPC_VARIANT=${ETHEREUM_JSONRPC_VARIANT:-geth}
export ETHEREUM_JSONRPC_HTTP_URL="${ETHEREUM_JSONRPC_HTTP_URL:-http://127.0.0.1:8545}"
export ETHEREUM_JSONRPC_TRACE_URL="${ETHEREUM_JSONRPC_TRACE_URL:-$ETHEREUM_JSONRPC_HTTP_URL}"
export ETHEREUM_JSONRPC_GETH_TRACE_BY_BLOCK=true
export CHAIN_ID="${CHAIN_ID:-31337}"

# indexer only, catchup only, so backfill is the only thing producing blocks
export APPLICATION_MODE=indexer
export DISABLE_API=true
export DISABLE_REALTIME_INDEXER=true
export INDEXER_DISABLE_PENDING_TRANSACTIONS_FETCHER=true
export INDEXER_DISABLE_BLOCK_REWARD_FETCHER=true
export INDEXER_DISABLE_ADDRESS_COIN_BALANCE_FETCHER=true
export INDEXER_DISABLE_CATALOGED_TOKEN_UPDATER_FETCHER=true

export BLOCK_RANGES="${BLOCK_RANGES:-1..1000}"
export INDEXER_CATCHUP_BLOCKS_BATCH_SIZE="${INDEXER_CATCHUP_BLOCKS_BATCH_SIZE:-10}"
export INDEXER_CATCHUP_BLOCKS_CONCURRENCY="${INDEXER_CATCHUP_BLOCKS_CONCURRENCY:-10}"

# export INDEXER_FIREHOSE_URL="http://127.0.0.1:8082"
# export INDEXER_FIREHOSE_TIMEOUT="120s"
