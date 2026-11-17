-- Catch-all partition for audit_log.
-- Migration 0001 only creates partitions for a few specific months, so writes
-- for any other month would fail with "no partition of relation found".

CREATE TABLE IF NOT EXISTS audit_log_default PARTITION OF audit_log DEFAULT;
