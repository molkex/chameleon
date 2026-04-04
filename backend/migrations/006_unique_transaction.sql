CREATE UNIQUE INDEX IF NOT EXISTS idx_users_original_txn_id
ON users(original_transaction_id)
WHERE original_transaction_id IS NOT NULL;
