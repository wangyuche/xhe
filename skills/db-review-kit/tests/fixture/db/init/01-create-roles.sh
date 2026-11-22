#!/bin/sh
# Runs once at initdb. Passwords come from env (psql \getenv), never from argv.
# Grants and schemas live in /roles.sql, mounted separately (not under initdb.d, which would auto-run it against "postgres").
set -eu
: "${FX_MIGRATOR_PASSWORD:?FX_MIGRATOR_PASSWORD is required}"
: "${FX_APP_PASSWORD:?FX_APP_PASSWORD is required}"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<'EOSQL'
CREATE DATABASE fx_test;
EOSQL
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname fx_test <<'EOSQL'
\getenv mig_pw FX_MIGRATOR_PASSWORD
\getenv app_pw FX_APP_PASSWORD
CREATE ROLE fx_migrator LOGIN PASSWORD :'mig_pw' NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE ROLE fx_app      LOGIN PASSWORD :'app_pw' NOSUPERUSER NOCREATEDB NOCREATEROLE;
EOSQL
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname fx_test -f /roles.sql
