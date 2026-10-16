-- 004: n8n runs `CREATE SCHEMA IF NOT EXISTS "n8n"` on every start. PostgreSQL checks
-- CREATE on the database before checking existence, so without this grant n8n hangs
-- silently at startup. Trade-off: n8n_app may create new schemas of its own; it still
-- gets no access to finance or any schema it does not own.
BEGIN;

DO $$
BEGIN
    EXECUTE format('GRANT CREATE ON DATABASE %I TO n8n_app', current_database());
END;
$$;

COMMIT;
