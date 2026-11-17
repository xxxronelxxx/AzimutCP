-- Schema alignment 3 — columns referenced by the application but never added.
-- Keep this migration additive and idempotent so it is safe on existing installs.

-- Sites: plan + runtime lifecycle columns used by provisioning, runtimes.rs and the watchdog.
ALTER TABLE sites ADD COLUMN IF NOT EXISTS plan           VARCHAR(32) NOT NULL DEFAULT 'community';
ALTER TABLE sites ADD COLUMN IF NOT EXISTS runtime_status VARCHAR(32) NOT NULL DEFAULT 'idle';
ALTER TABLE sites ADD COLUMN IF NOT EXISTS runtime_entry  TEXT;
ALTER TABLE sites ADD COLUMN IF NOT EXISTS runtime_error  TEXT;

-- Server metrics: RAM percentage is written by azimut-cron and streamed to the dashboard.
ALTER TABLE server_metrics ADD COLUMN IF NOT EXISTS ram_pct DOUBLE PRECISION;

-- Migration jobs: source panel type (cpanel, plesk, ...).
ALTER TABLE migration_jobs ADD COLUMN IF NOT EXISTS source_type VARCHAR(32) NOT NULL DEFAULT 'cpanel';

-- DNSBL alerts: timestamp of the notification e-mail.
ALTER TABLE blacklist_alerts ADD COLUMN IF NOT EXISTS notified_at TIMESTAMPTZ;
