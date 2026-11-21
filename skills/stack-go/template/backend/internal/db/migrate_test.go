package db

import (
	"context"
	"database/sql"
	"path/filepath"
	"sort"
	"testing"
)

// TestMigrationsOnFreshDB applies all migrations to a brand-new SQLite file
// and checks each table's columns. Add an entry to `want` for every new table.
func TestMigrationsOnFreshDB(t *testing.T) {
	dsn := "file:" + filepath.Join(t.TempDir(), "fresh.db") + "?_pragma=foreign_keys(1)"
	database, err := Open(context.Background(), dsn)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer database.Close()

	want := map[string][]string{
		// "users": {"created_at", "email", "id", "password_hash"},
	}
	for table, cols := range want {
		got := columns(t, database, table)
		sort.Strings(cols)
		if len(got) != len(cols) {
			t.Errorf("%s: columns %v, want %v", table, got, cols)
			continue
		}
		for i := range cols {
			if got[i] != cols[i] {
				t.Errorf("%s: columns %v, want %v", table, got, cols)
				break
			}
		}
	}
}

func columns(t *testing.T, database *sql.DB, table string) []string {
	t.Helper()
	rows, err := database.Query("SELECT name FROM pragma_table_info(?)", table)
	if err != nil {
		t.Fatalf("%s: %v", table, err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			t.Fatal(err)
		}
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// TestOpenRejectsPerConnectionSQLite: in-memory DSNs give every pooled connection its own
// empty database, so concurrent tests fail with "no such table". Tests use t.TempDir() files.
func TestOpenRejectsPerConnectionSQLite(t *testing.T) {
	for _, dsn := range []string{":memory:", "file::memory:", "file::memory:?cache=shared", "file:x?mode=memory&cache=shared", ""} {
		if database, err := Open(context.Background(), dsn); err == nil {
			database.Close()
			t.Errorf("Open(%q) succeeded, want error", dsn)
		}
	}
}
