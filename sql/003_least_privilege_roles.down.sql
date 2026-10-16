-- Reverts 003. Fails on purpose if the n8n schema still holds n8n's state:
-- dropping it would erase workflows and credentials.
BEGIN;

GRANT EXECUTE ON FUNCTION
    finance.period_start(TEXT, TIMESTAMPTZ),
    finance.summary(TEXT, TEXT, TIMESTAMPTZ),
    finance.record_transaction(TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT),
    finance.undo_last(TEXT)
TO PUBLIC;

REVOKE ALL ON FUNCTION
    finance.period_start(TEXT, TIMESTAMPTZ),
    finance.summary(TEXT, TEXT, TIMESTAMPTZ),
    finance.record_transaction(TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT),
    finance.undo_last(TEXT)
FROM bot_app;
REVOKE ALL ON finance.transactions FROM bot_app;
REVOKE ALL ON SCHEMA finance FROM bot_app;

DROP SCHEMA n8n;
REVOKE n8n_app FROM CURRENT_USER;
DROP ROLE bot_app;
DROP ROLE n8n_app;

COMMIT;
