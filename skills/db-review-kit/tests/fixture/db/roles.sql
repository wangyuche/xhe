-- Least-privilege roles for the fixture (idempotent).
--   fx_migrator: owns schemas fx and fx_meta (DDL)
--   fx_app     : DML on fx only; no access to fx_meta (goose version table)
REVOKE ALL ON DATABASE fx_test FROM PUBLIC;
GRANT CONNECT ON DATABASE fx_test TO fx_migrator, fx_app;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

CREATE SCHEMA IF NOT EXISTS fx AUTHORIZATION fx_migrator;
REVOKE ALL ON SCHEMA fx FROM PUBLIC;
GRANT USAGE ON SCHEMA fx TO fx_app;
ALTER DEFAULT PRIVILEGES FOR ROLE fx_migrator IN SCHEMA fx
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO fx_app;

CREATE SCHEMA IF NOT EXISTS fx_meta AUTHORIZATION fx_migrator;
REVOKE ALL ON SCHEMA fx_meta FROM PUBLIC;

ALTER ROLE fx_migrator SET search_path = fx;
ALTER ROLE fx_app      SET search_path = fx;
ALTER ROLE fx_app      SET statement_timeout = '5s';
