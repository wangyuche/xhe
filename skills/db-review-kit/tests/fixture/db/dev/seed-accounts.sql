-- Project seed script example: psql -v n=<rows> -f seed-accounts.sql (run as the migrator / superuser).
INSERT INTO fx.accounts (name, balance)
SELECT 'user-' || g, (g % 1000) FROM generate_series(1, :n) AS g;
ANALYZE fx.accounts;
