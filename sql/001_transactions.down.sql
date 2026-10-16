-- Reverts 001. Destroys all transaction data.
BEGIN;

DROP TABLE finance.transactions;
DROP SCHEMA finance;

COMMIT;
