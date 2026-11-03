-- Existing-install migration: tokenbf_v1 `idx_msg` -> text index `idx_msg_text`
-- on the free-text message columns (see "Message search index" in 020_hosts.sql).
--
-- 020_hosts.sql is CREATE TABLE IF NOT EXISTS, so it never alters a table that
-- already exists. This file brings those tables up to the same definition. It
-- is safe on every boot (ironlog-apply-schema.sh re-runs all DDL): ADD INDEX
-- IF NOT EXISTS is a metadata no-op once converged, and on a fresh install the
-- tables were just created with idx_msg_text, so it does nothing.
--
-- Only the ADD lives here. The rest is conditional, so it is done by
-- initdb/99-init.sh: ADD INDEX only covers NEW parts, so the script runs
-- `ALTER TABLE ... MATERIALIZE INDEX idx_msg_text` once for tables that lacked
-- the index before this file ran, and only THEN drops the old tokenbf_v1
-- `idx_msg` (so a failure part-way never leaves a table with no message index).
-- DROP INDEX IF EXISTS is not used here because it queues a mutation on every
-- boot even when the index is already gone. Until materialization finishes,
-- hasAllTokens() on old parts falls back to a (correct, slower) scan.
-- The definition below MUST match 020_hosts.sql exactly.

ALTER TABLE siem.windows_events ADD INDEX IF NOT EXISTS idx_msg_text message TYPE text(tokenizer = splitByNonAlpha, preprocessor = lower(message));

ALTER TABLE siem.linux_syslog ADD INDEX IF NOT EXISTS idx_msg_text message TYPE text(tokenizer = splitByNonAlpha, preprocessor = lower(message));

ALTER TABLE siem.k8s_logs ADD INDEX IF NOT EXISTS idx_msg_text message TYPE text(tokenizer = splitByNonAlpha, preprocessor = lower(message));
