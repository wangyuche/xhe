// Package db opens the database and applies embedded goose migrations on startup.
package db

import (
	"context"
	"database/sql"
	"embed"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	_ "modernc.org/sqlite"
)

//go:embed migrations/*.sql
var migrations embed.FS

const DefaultSQLiteURL = "file:data/dev.db?_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)"

// sqliteSafety is appended to every SQLite DSN that lacks it: concurrent writers wait
// (busy_timeout) instead of failing with SQLITE_BUSY, and write transactions take the
// write lock up front (_txlock=immediate). Each entry: {substring that means "already set", param to add}.
var sqliteSafety = [][2]string{
	{"busy_timeout(", "_pragma=busy_timeout(5000)"},
	{"_txlock=", "_txlock=immediate"},
}

// Open connects using DATABASE_URL semantics: "postgres://…" → pgx, otherwise SQLite DSN.
func Open(ctx context.Context, url string) (*sql.DB, error) {
	driver, dialect := "sqlite", "sqlite3"
	if strings.HasPrefix(url, "postgres://") || strings.HasPrefix(url, "postgresql://") {
		driver, dialect = "pgx", "postgres"
	} else {
		if perConnectionSQLite(url) {
			return nil, fmt.Errorf("SQLite DSN %q is a per-connection database (in-memory or empty path): each pooled connection would see its own empty database; use a file such as filepath.Join(t.TempDir(), \"test.db\")", url)
		}
		if err := ensureDir(url); err != nil {
			return nil, err
		}
		url = withSQLiteSafety(url)
	}
	database, err := sql.Open(driver, url)
	if err != nil {
		return nil, err
	}
	if err := database.PingContext(ctx); err != nil {
		database.Close()
		return nil, fmt.Errorf("ping database: %w", err)
	}
	if err := Migrate(ctx, database, dialect); err != nil {
		database.Close()
		return nil, err
	}
	return database, nil
}

func Migrate(ctx context.Context, database *sql.DB, dialect string) error {
	goose.SetBaseFS(migrations)
	if err := goose.SetDialect(dialect); err != nil {
		return err
	}
	goose.SetLogger(goose.NopLogger())
	if err := goose.UpContext(ctx, database, "migrations"); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}
	return nil
}

func withSQLiteSafety(dsn string) string {
	for _, p := range sqliteSafety {
		if strings.Contains(dsn, p[0]) {
			continue
		}
		sep := "?"
		if strings.Contains(dsn, "?") {
			sep = "&"
		}
		dsn += sep + p[1]
	}
	return dsn
}

// perConnectionSQLite reports DSNs whose database exists only inside one connection
// (":memory:", "file::memory:", mode=memory, or an empty path). database/sql pools
// connections, so the second connection sees an empty database without the migrated
// tables ("no such table" under concurrent tests). Shared-cache memory DBs are rejected
// too: shared cache uses table locks that ignore busy_timeout (SQLITE_LOCKED).
func perConnectionSQLite(dsn string) bool {
	path, query := strings.TrimPrefix(dsn, "file:"), ""
	if i := strings.IndexByte(path, '?'); i >= 0 {
		path, query = path[:i], path[i+1:]
	}
	if path == "" || strings.HasPrefix(path, ":memory:") {
		return true
	}
	for _, kv := range strings.Split(query, "&") {
		if strings.EqualFold(kv, "mode=memory") {
			return true
		}
	}
	return false
}

// ensureDir creates the directory of a SQLite file DSN (data/ is gitignored, so a fresh worktree lacks it).
func ensureDir(dsn string) error {
	path := strings.TrimPrefix(dsn, "file:")
	if i := strings.IndexByte(path, '?'); i >= 0 {
		path = path[:i]
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		wd, _ := os.Getwd()
		return fmt.Errorf("create SQLite directory %q (working directory %q): %w; set DATABASE_URL or run from a writable directory", dir, wd, err)
	}
	return nil
}
