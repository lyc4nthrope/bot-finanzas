-- 001: transactions table. Rules mirror docs/contract.md.
BEGIN;

-- Own schema instead of "public": Supabase exposes "public" through its REST API.
CREATE SCHEMA finance;

CREATE TABLE finance.transactions (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- Discord interaction id: makes a repeated delivery of the same command a no-op.
    interaction_id TEXT        NOT NULL UNIQUE,
    -- Discord user id (snowflake).
    user_id        TEXT        NOT NULL CHECK (user_id ~ '^[0-9]{17,20}$'),
    type           TEXT        NOT NULL CHECK (type IN ('income', 'expense')),
    -- NUMERIC, never FLOAT: floating point cannot represent money exactly.
    amount         NUMERIC(14, 2) NOT NULL CHECK (amount > 0 AND amount <= 1000000000),
    category       TEXT        NOT NULL,
    note           TEXT        CHECK (char_length(note) <= 200),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT category_matches_type CHECK (
        (type = 'expense' AND category IN
            ('mercado', 'comida', 'transporte', 'servicios', 'hogar', 'salud', 'deudas', 'otro'))
        OR
        (type = 'income' AND category IN ('sueldo', 'ventas', 'regalo', 'otro'))
    )
);

-- Serves every query in the contract: per-user, filtered or ordered by date.
CREATE INDEX transactions_user_created_idx
    ON finance.transactions (user_id, created_at DESC);

COMMIT;
