-- Roles ------------------------------------------------------------------
-- siem_ingest   : write-only pipeline account (Vector). Cannot read anything.
-- siem_analyst  : full read on siem.*; runs investigations from Grafana.
-- siem_auditor  : read on siem.* AND audit.* (can review analyst activity).
-- Admin duties use the bootstrap admin user (CH_ADMIN_USER) which has
-- access_management enabled; no separate admin role is created here.

CREATE ROLE IF NOT EXISTS siem_ingest;
CREATE ROLE IF NOT EXISTS siem_analyst;
CREATE ROLE IF NOT EXISTS siem_auditor;

GRANT INSERT ON siem.* TO siem_ingest;

GRANT SELECT ON siem.* TO siem_analyst;
GRANT SELECT ON siem.* TO siem_auditor;
GRANT SELECT ON audit.* TO siem_auditor;

-- Guardrails: cap what any single query can burn -----------------------------
CREATE SETTINGS PROFILE IF NOT EXISTS siem_reader SETTINGS
    readonly = 2,                        -- SELECT + SET only, no DDL/DML
    max_memory_usage = 8000000000,       -- 8 GB per query
    max_execution_time = 120,            -- seconds
    max_rows_to_read = 20000000000
    TO siem_analyst, siem_auditor;

-- Example row policy (commented): restrict an auditor group to one AWS account.
-- CREATE ROW POLICY prod_only ON siem.cloudtrail
--     FOR SELECT USING aws_account = '111122223333' TO siem_auditor;

-- Service accounts are created by initdb/99-rbac.sh with passwords from the
-- environment (.env): svc_vector, svc_grafana_analyst, svc_grafana_auditor.
