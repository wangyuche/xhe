package db

import (
	"context"
	"path/filepath"
	"sync"
	"testing"
)

// TestConcurrentWrites: parallel write transactions must all succeed (no SQLITE_BUSY).
// Regression for the integration-verifier finding on 2026-11-16 (two simultaneous logins → 500).
func TestConcurrentWrites(t *testing.T) {
	dsn := "file:" + filepath.Join(t.TempDir(), "c.db") + "?_pragma=journal_mode(WAL)"
	database, err := Open(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	if _, err := database.Exec(`CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)`); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	errs := make(chan error, 20)
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			tx, err := database.Begin()
			if err != nil {
				errs <- err
				return
			}
			if _, err := tx.Exec(`INSERT INTO t (v) VALUES ('x')`); err != nil {
				tx.Rollback()
				errs <- err
				return
			}
			errs <- tx.Commit()
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Errorf("concurrent write failed: %v", err)
		}
	}
}
