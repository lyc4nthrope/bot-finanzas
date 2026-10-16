-- Reverts 004.
BEGIN;

DO $$
BEGIN
    EXECUTE format('REVOKE CREATE ON DATABASE %I FROM n8n_app', current_database());
END;
$$;

COMMIT;
