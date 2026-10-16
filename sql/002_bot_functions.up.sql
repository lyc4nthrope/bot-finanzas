-- 002: business operations called by the bot. Behaviour mirrors docs/contract.md.
-- Every function takes an optional p_now so tests can pin "the current moment".
BEGIN;

-- Start of the current period on the Bogota calendar, as an absolute instant.
-- Weeks start on Monday (ISO), as the contract requires.
CREATE FUNCTION finance.period_start(p_period TEXT, p_now TIMESTAMPTZ DEFAULT now())
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_unit TEXT := CASE p_period
        WHEN 'hoy' THEN 'day'
        WHEN 'semana' THEN 'week'
        WHEN 'mes' THEN 'month'
        WHEN 'año' THEN 'year'
    END;
BEGIN
    IF v_unit IS NULL THEN
        RAISE EXCEPTION 'unknown period: %', p_period;
    END IF;
    RETURN date_trunc(v_unit, p_now AT TIME ZONE 'America/Bogota') AT TIME ZONE 'America/Bogota';
END;
$$;

-- Income, expenses and expenses by category for the period, plus the all-time balance.
CREATE FUNCTION finance.summary(p_user_id TEXT, p_period TEXT, p_now TIMESTAMPTZ DEFAULT now())
RETURNS JSONB
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_start TIMESTAMPTZ := finance.period_start(p_period, p_now);
BEGIN
    RETURN jsonb_build_object(
        'period', p_period,
        'income', COALESCE((
            SELECT sum(amount) FROM finance.transactions
            WHERE user_id = p_user_id AND type = 'income'
              AND created_at >= v_start AND created_at <= p_now), 0),
        'expense', COALESCE((
            SELECT sum(amount) FROM finance.transactions
            WHERE user_id = p_user_id AND type = 'expense'
              AND created_at >= v_start AND created_at <= p_now), 0),
        'balance', COALESCE((
            SELECT sum(CASE type WHEN 'income' THEN amount ELSE -amount END)
            FROM finance.transactions
            WHERE user_id = p_user_id AND created_at <= p_now), 0),
        'by_category', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('category', category, 'total', total)
                             ORDER BY total DESC, category)
            FROM (
                SELECT category, sum(amount) AS total FROM finance.transactions
                WHERE user_id = p_user_id AND type = 'expense'
                  AND created_at >= v_start AND created_at <= p_now
                GROUP BY category
            ) AS per_category), '[]'::jsonb)
    );
END;
$$;

-- Stores one transaction. A repeated interaction id is ignored (inserted = false).
-- Invalid data raises an error from the table constraints, so nothing is confirmed.
CREATE FUNCTION finance.record_transaction(
    p_interaction_id TEXT,
    p_user_id TEXT,
    p_type TEXT,
    p_amount NUMERIC,
    p_category TEXT,
    p_note TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_inserted BOOLEAN;
BEGIN
    INSERT INTO finance.transactions (interaction_id, user_id, type, amount, category, note)
    VALUES (p_interaction_id, p_user_id, p_type, p_amount, p_category, NULLIF(btrim(p_note), ''))
    ON CONFLICT (interaction_id) DO NOTHING;
    v_inserted := FOUND;

    RETURN jsonb_build_object(
        'inserted', v_inserted,
        'type', p_type,
        'amount', p_amount,
        'category', p_category
    ) || finance.summary(p_user_id, 'mes');
END;
$$;

-- Deletes the user's most recent transaction and returns it.
CREATE FUNCTION finance.undo_last(p_user_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_row finance.transactions;
BEGIN
    DELETE FROM finance.transactions
    WHERE id = (
        SELECT id FROM finance.transactions
        WHERE user_id = p_user_id
        ORDER BY created_at DESC, id DESC
        LIMIT 1
    )
    RETURNING * INTO v_row;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('deleted', false);
    END IF;

    RETURN jsonb_build_object(
        'deleted', true,
        'type', v_row.type,
        'amount', v_row.amount,
        'category', v_row.category
    ) || finance.summary(p_user_id, 'mes');
END;
$$;

COMMIT;
