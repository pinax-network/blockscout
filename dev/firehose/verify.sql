\pset pager off
\echo '--- row counts ---'
SELECT 'blocks'                     AS table, count(*) FROM blocks
UNION ALL SELECT 'blocks_consensus',          count(*) FROM blocks WHERE consensus
UNION ALL SELECT 'transactions',              count(*) FROM transactions
UNION ALL SELECT 'logs',                      count(*) FROM logs
UNION ALL SELECT 'internal_transactions',     count(*) FROM internal_transactions
UNION ALL SELECT 'signed_authorizations',      count(*) FROM signed_authorizations
UNION ALL SELECT 'addresses',                 count(*) FROM addresses
UNION ALL SELECT 'pending_block_operations',  count(*) FROM pending_block_operations
UNION ALL SELECT 'missing_block_ranges',      count(*) FROM missing_block_ranges
ORDER BY 1;

\echo ''
\echo '--- block range covered ---'
SELECT min(number) AS min_block, max(number) AS max_block, count(*) AS blocks FROM blocks WHERE consensus;

\echo ''
\echo '--- internal transactions (the thing Firehose supplies inline) ---'
SELECT it.block_number,
       it.transaction_index,
       it.index,
       it.type,
       encode(it.from_address_hash, 'hex') AS from_addr,
       encode(it.to_address_hash,   'hex') AS to_addr,
       it.value
FROM internal_transactions it
ORDER BY it.block_number, it.transaction_index, it.index;

\echo ''
\echo '--- fingerprint: stable hash of the indexed data, for A/B comparison ---'
SELECT 'blocks' AS dataset,
       md5(string_agg(number || ':' || encode(hash,'hex') || ':' || consensus, ',' ORDER BY number)) AS fingerprint
FROM blocks
UNION ALL
SELECT 'transactions',
       md5(string_agg(encode(hash,'hex') || ':' || block_number || ':' || index || ':' || type ||
                      ':' || coalesce(gas::text,'') || ':' || coalesce(gas_price::text,'') ||
                      ':' || coalesce(value::text,'') || ':' || coalesce(encode(input,'hex'),''),
                      ',' ORDER BY block_number, index))
FROM transactions
UNION ALL
SELECT 'internal_transactions',
       md5(string_agg(block_number || ':' || transaction_index || ':' || index || ':' || type ||
                      ':' || coalesce(call_type::text,'') || ':' || coalesce(encode(to_address_hash,'hex'),'') ||
                      ':' || coalesce(value::text,'') || ':' || coalesce(gas::text,'') ||
                      ':' || coalesce(gas_used::text,'') || ':' || coalesce(encode(input,'hex'),'') ||
                      ':' || coalesce(encode(output,'hex'),'') || ':' || coalesce(trace_address::text,''),
                      ',' ORDER BY block_number, transaction_index, index))
FROM internal_transactions
UNION ALL
SELECT 'signed_authorizations',
       md5(string_agg(encode(transaction_hash,'hex') || ':' || index || ':' || chain_id || ':' ||
                      encode(address,'hex') || ':' || nonce || ':' || v || ':' || r || ':' || s,
                      ',' ORDER BY transaction_hash, index))
FROM signed_authorizations
ORDER BY 1;

\echo ''
\echo '--- Ethereum Cancun/Prague extensions (when beacon migrations are installed) ---'
SELECT to_regclass('public.beacon_blobs_transactions') IS NOT NULL AS has_beacon_tables \gset
\if :has_beacon_tables
SELECT number, blob_gas_used, excess_blob_gas
FROM blocks
WHERE blob_gas_used IS NOT NULL OR excess_blob_gas IS NOT NULL
ORDER BY number;

SELECT count(*) AS blob_transactions,
       md5(string_agg(encode(hash,'hex') || ':' || max_fee_per_blob_gas || ':' || blob_gas_price ||
                      ':' || blob_gas_used || ':' || blob_versioned_hashes::text,
                      ',' ORDER BY hash)) AS fingerprint
FROM beacon_blobs_transactions;
\else
\echo 'beacon tables are not installed for this chain type'
\endif
