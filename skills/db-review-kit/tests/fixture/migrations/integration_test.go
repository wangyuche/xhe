//go:build integration

// Integration tests for the db-review-kit fixture. DSNs come only from these variables:
//
//	FX_MIGRATOR_DSN  fx_migrator on fx_test (required; tests skip without it)
//	FX_APP_DSN       fx_app on fx_test (required)
//	FX_AUDIT_DSN     optional audit role; its test skips when unset (the kit must count that SKIP)
package migrations_test

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

const versionTable = "fx_meta.goose_db_version"

var (
	migrateOnce sync.Once
	migrateErr  error
)

func open(t *testing.T, envName string) *sql.DB {
	t.Helper()
	dsn := os.Getenv(envName)
	if dsn == "" {
		t.Skipf("%s not set", envName)
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatalf("open %s: %v", envName, err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

func migrated(t *testing.T) {
	t.Helper()
	db := open(t, "FX_MIGRATOR_DSN")
	migrateOnce.Do(func() {
		p, err := goose.NewProvider(goose.DialectPostgres, db, os.DirFS("."), goose.WithTableName(versionTable))
		if err != nil {
			migrateErr = err
			return
		}
		_, migrateErr = p.Up(context.Background())
	})
	if migrateErr != nil {
		t.Fatalf("migrate up: %v", migrateErr)
	}
}

func sqlState(err error) string {
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		return pe.Code
	}
	return ""
}

// The kit runs tests under env -i; ambient connection settings must never reach the test process.
func TestNoAmbientConnectionEnv(t *testing.T) {
	// the kit sets dead-end PGHOST / PGPORT on purpose; anything else from the calling shell is a leak
	sentinel := map[string]string{"PGHOST": "/nonexistent-dbrev-pghost", "PGPORT": "1"}
	for _, k := range []string{"DATABASE_URL", "PGHOST", "PGPORT", "PGUSER", "PGPASSWORD", "PGDATABASE", "TEST_DATABASE_URL"} {
		if v, ok := os.LookupEnv(k); ok && v != sentinel[k] {
			t.Fatalf("ambient %s leaked into the test environment (len=%d)", k, len(v))
		}
	}
}

func TestMigrateUp(t *testing.T) {
	migrated(t)
}

func TestAppColumnGrants(t *testing.T) {
	migrated(t)
	app := open(t, "FX_APP_DSN")
	ctx := context.Background()
	t.Run("select id,name allowed", func(t *testing.T) {
		if _, err := app.ExecContext(ctx, "SELECT id, name FROM accounts LIMIT 1"); err != nil {
			t.Fatalf("want ok, got %v", err)
		}
	})
	t.Run("select balance denied", func(t *testing.T) {
		_, err := app.ExecContext(ctx, "SELECT balance FROM accounts LIMIT 1")
		if sqlState(err) != "42501" {
			t.Fatalf("want 42501, got %v", err)
		}
	})
	t.Run("ledger update denied", func(t *testing.T) {
		_, err := app.ExecContext(ctx, "UPDATE ledger SET amount = amount WHERE false")
		if sqlState(err) != "42501" {
			t.Fatalf("want 42501, got %v", err)
		}
	})
}

func TestAuditRoleSmoke(t *testing.T) {
	if os.Getenv("FX_AUDIT_DSN") == "" {
		t.Skip("FX_AUDIT_DSN not set; audit role smoke test skipped")
	}
	_ = open(t, "FX_AUDIT_DSN")
}
