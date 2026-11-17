-- Server metrics columns streamed by azimut-agent and stored by azimut-cron.
-- The original 0014 table only had the *_mb / load_1min variants.

ALTER TABLE server_metrics ADD COLUMN IF NOT EXISTS ram_used_bytes  BIGINT;
ALTER TABLE server_metrics ADD COLUMN IF NOT EXISTS ram_total_bytes BIGINT;
ALTER TABLE server_metrics ADD COLUMN IF NOT EXISTS disk_read_kbps  BIGINT;
ALTER TABLE server_metrics ADD COLUMN IF NOT EXISTS disk_write_kbps BIGINT;
ALTER TABLE server_metrics ADD COLUMN IF NOT EXISTS net_rx_kbps     BIGINT;
ALTER TABLE server_metrics ADD COLUMN IF NOT EXISTS net_tx_kbps     BIGINT;
ALTER TABLE server_metrics ADD COLUMN IF NOT EXISTS load_1          DOUBLE PRECISION;
ALTER TABLE server_metrics ADD COLUMN IF NOT EXISTS load_5          DOUBLE PRECISION;
ALTER TABLE server_metrics ADD COLUMN IF NOT EXISTS load_15         DOUBLE PRECISION;
