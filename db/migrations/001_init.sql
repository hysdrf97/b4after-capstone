-- Users table
CREATE TABLE IF NOT EXISTS users (
    id          BIGSERIAL PRIMARY KEY,
    name        VARCHAR(100) NOT NULL,
    email       VARCHAR(100) UNIQUE NOT NULL,
    balance     NUMERIC(18,2) NOT NULL DEFAULT 0,
    created_at  TIMESTAMP DEFAULT NOW()
);

-- Transactions table
CREATE TABLE IF NOT EXISTS transactions (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT REFERENCES users(id),
    type            VARCHAR(20) NOT NULL,  -- 'credit' / 'debit'
    amount          NUMERIC(18,2) NOT NULL,
    status          VARCHAR(20) DEFAULT 'pending', -- 'pending','success','failed'
    reference_id    UUID DEFAULT gen_random_uuid(),
    created_at      TIMESTAMP DEFAULT NOW()
);

-- Index untuk read-heavy queries
CREATE INDEX IF NOT EXISTS idx_transactions_user_id ON transactions(user_id);
CREATE INDEX IF NOT EXISTS idx_transactions_status ON transactions(status);

-- Dummy data: 1000 users
INSERT INTO users (name, email, balance)
SELECT
    'User ' || i,
    'user' || i || '@bank.com',
    (random() * 10000000)::numeric(18,2)
FROM generate_series(1, 1000) AS i;

-- Dummy data: 50000 transactions
INSERT INTO transactions (user_id, type, amount, status)
SELECT
    (random() * 999 + 1)::bigint,
    CASE WHEN random() > 0.5 THEN 'credit' ELSE 'debit' END,
    (random() * 5000000)::numeric(18,2),
    CASE
        WHEN random() < 0.8 THEN 'success'
        WHEN random() < 0.9 THEN 'pending'
        ELSE 'failed'
    END
FROM generate_series(1, 50000);