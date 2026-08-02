\pset pager off
\echo '--- row counts ---'
SELECT 'blocks'                     AS table, count(*) FROM blocks
UNION ALL SELECT 'blocks_consensus',          count(*) FROM blocks WHERE consensus
UNION ALL SELECT 'transactions',              count(*) FROM transactions
UNION ALL SELECT 'logs',                      count(*) FROM logs
UNION ALL SELECT 'internal_transactions',     count(*) FROM internal_transactions
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
       md5(string_agg(encode(hash,'hex') || ':' || block_number || ':' || index, ',' ORDER BY block_number, index))
FROM transactions
UNION ALL
SELECT 'internal_transactions',
       md5(string_agg(block_number || ':' || transaction_index || ':' || index || ':' || type ||
                      ':' || coalesce(encode(to_address_hash,'hex'),'') || ':' || coalesce(value::text,''),
                      ',' ORDER BY block_number, transaction_index, index))
FROM internal_transactions
ORDER BY 1;
