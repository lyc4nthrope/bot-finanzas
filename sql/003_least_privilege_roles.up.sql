-- 003: least-privilege roles. No passwords here: scripts/setup-roles.sh enables
-- LOGIN and sets them from .env, so no secret lives in the repository.
BEGIN;

CREATE ROLE n8n_app NOLOGIN;
CREATE ROLE bot_app NOLOGIN;

-- The migrating user must be a member to hand schema ownership to n8n_app
-- (required on Supabase, where "postgres" is not a superuser).
GRANT n8n_app TO CURRENT_USER;

-- n8n keeps its internal state in a schema it owns, and touches nothing else.
CREATE SCHEMA n8n AUTHORIZATION n8n_app;

-- bot_app gets exactly what the workflow needs: no UPDATE, no DDL.
GRANT USAGE ON SCHEMA finance TO bot_app;
GRANT SELECT, INSERT, DELETE ON finance.transactions TO bot_app;

-- Functions are executable by PUBLIC by default; restrict them to bot_app.
REVOKE EXECUTE ON FUNCTION
    finance.period_start(TEXT, TIMESTAMPTZ),
    finance.summary(TEXT, TEXT, TIMESTAMPTZ),
    finance.record_transaction(TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT),
    finance.undo_last(TEXT)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    finance.period_start(TEXT, TIMESTAMPTZ),
    finance.summary(TEXT, TEXT, TIMESTAMPTZ),
    finance.record_transaction(TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT),
    finance.undo_last(TEXT)
TO bot_app;

COMMIT;
