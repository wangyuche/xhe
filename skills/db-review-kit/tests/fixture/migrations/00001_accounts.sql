-- +goose Up
SET LOCAL lock_timeout = '2s';
CREATE TABLE accounts (
  id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name    text   NOT NULL,
  balance bigint NOT NULL DEFAULT 0 CHECK (balance >= 0)
);
-- Column-level grants: schema default privileges give fx_app full DML, so revoke first, then grant per column.
REVOKE ALL ON accounts FROM fx_app;
GRANT SELECT (id, name), INSERT (name), UPDATE (name) ON accounts TO fx_app;

-- Ledger: ref is the idempotency key (one credit per ref).
CREATE TABLE ledger (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id bigint NOT NULL REFERENCES accounts (id),
  ref        text   NOT NULL,
  amount     bigint NOT NULL,
  CONSTRAINT ledger_ref_key UNIQUE (ref)
);
REVOKE UPDATE, DELETE, TRUNCATE ON ledger FROM fx_app;

-- +goose Down
SET LOCAL lock_timeout = '2s';
DROP TABLE ledger;
DROP TABLE accounts;
