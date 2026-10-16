-- Reverts 002. Data in finance.transactions is untouched.
BEGIN;

DROP FUNCTION finance.undo_last(TEXT);
DROP FUNCTION finance.record_transaction(TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT);
DROP FUNCTION finance.summary(TEXT, TEXT, TIMESTAMPTZ);
DROP FUNCTION finance.period_start(TEXT, TIMESTAMPTZ);

COMMIT;
