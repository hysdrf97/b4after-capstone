-- ==============================================================
-- PostgreSQL Initialization Script
-- B4 After - Database Setup
-- ==============================================================

-- Buat user replication untuk read replica
CREATE USER replicator WITH REPLICATION ENCRYPTED PASSWORD 'replicator_secret';

-- ==============================================================
-- TABLES - Skema database simulasi transaksi bank
-- ==============================================================

-- Tabel user/nasabah
CREATE TABLE IF NOT EXISTS users (
    id          BIGSERIAL PRIMARY KEY,
    user_id     VARCHAR(20) UNIQUE NOT NULL,
    name        VARCHAR(100) NOT NULL,
    email       VARCHAR(100),
    phone       VARCHAR(20),
    created_at  TIMESTAMP DEFAULT NOW()
);

-- Tabel akun bank
CREATE TABLE IF NOT EXISTS accounts (
    id          BIGSERIAL PRIMARY KEY,
    account_id  VARCHAR(20) UNIQUE NOT NULL,
    user_id     VARCHAR(20) REFERENCES users(user_id),
    balance     DECIMAL(15, 2) DEFAULT 0,
    status      VARCHAR(10) DEFAULT 'active',
    updated_at  TIMESTAMP DEFAULT NOW()
);

-- Tabel transaksi (write-heavy table)
CREATE TABLE IF NOT EXISTS transactions (
    id              BIGSERIAL PRIMARY KEY,
    transaction_id  VARCHAR(36) UNIQUE NOT NULL,
    from_account    VARCHAR(20),
    to_account      VARCHAR(20),
    amount          DECIMAL(15, 2) NOT NULL,
    type            VARCHAR(20) NOT NULL,  -- transfer, payment, inquiry
    status          VARCHAR(20) DEFAULT 'pending',
    created_at      TIMESTAMP DEFAULT NOW(),
    completed_at    TIMESTAMP
);

-- ==============================================================
-- INDEX - Untuk performa query
-- ==============================================================
CREATE INDEX idx_transactions_from_account ON transactions(from_account);
CREATE INDEX idx_transactions_created_at ON transactions(created_at DESC);
CREATE INDEX idx_transactions_status ON transactions(status);
CREATE INDEX idx_accounts_user_id ON accounts(user_id);

-- ==============================================================
-- DUMMY DATA - Data simulasi untuk testing
-- ==============================================================

-- Insert 100 user dummy
INSERT INTO users (user_id, name, email, phone)
SELECT
    'USR' || LPAD(i::TEXT, 6, '0'),
    'User Dummy ' || i,
    'user' || i || '@email.com',
    '08' || LPAD((random() * 999999999)::BIGINT::TEXT, 9, '0')
FROM generate_series(1, 100) AS i
ON CONFLICT DO NOTHING;

-- Insert akun untuk setiap user
INSERT INTO accounts (account_id, user_id, balance)
SELECT
    'ACC' || LPAD(i::TEXT, 8, '0'),
    'USR' || LPAD(i::TEXT, 6, '0'),
    (random() * 10000000)::DECIMAL(15,2)
FROM generate_series(1, 100) AS i
ON CONFLICT DO NOTHING;

-- Insert 1000 transaksi dummy
INSERT INTO transactions (transaction_id, from_account, to_account, amount, type, status)
SELECT
    gen_random_uuid()::TEXT,
    'ACC' || LPAD((1 + random() * 99)::INT::TEXT, 8, '0'),
    'ACC' || LPAD((1 + random() * 99)::INT::TEXT, 8, '0'),
    (random() * 1000000)::DECIMAL(15,2),
    CASE (random() * 2)::INT
        WHEN 0 THEN 'transfer'
        WHEN 1 THEN 'payment'
        ELSE 'inquiry'
    END,
    'completed'
FROM generate_series(1, 1000)
ON CONFLICT DO NOTHING;

-- Berikan hak akses ke replicator
GRANT SELECT ON ALL TABLES IN SCHEMA public TO replicator;
