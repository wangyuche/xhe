// Package httpapi registers every HTTP endpoint from one route table.
// The contract test compares this table with the OpenAPI contract.
// Handlers live in domain packages (internal/auth, …) and use internal/httpx.
package httpapi

import (
	"net/http"
	"os"
	"strings"

	"__MODULE__/internal/httpx"
)

// Route is one endpoint. Pattern is a Go 1.22+ ServeMux path ("/api/items/{id}").
type Route struct {
	Method  string
	Pattern string
	Handler func(httpx.Deps) http.HandlerFunc
}

// Routes is the single source of truth for registered endpoints.
// Add new endpoints here; contract_test.go fails if this table and the contract disagree.
func Routes() []Route {
	return []Route{
		{Method: http.MethodGet, Pattern: "/healthz", Handler: healthz},
	}
}

func NewHandler(d httpx.Deps) http.Handler {
	mux := http.NewServeMux()
	for _, r := range Routes() {
		mux.HandleFunc(r.Method+" "+r.Pattern, r.Handler(d))
	}
	return withCORS(mux)
}

func healthz(httpx.Deps) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}

func withCORS(next http.Handler) http.Handler {
	allowed := map[string]bool{}
	origins := os.Getenv("CORS_ORIGINS")
	if origins == "" {
		origins = "http://localhost:3000"
	}
	for _, o := range strings.Split(origins, ",") {
		allowed[strings.TrimSpace(o)] = true
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if o := r.Header.Get("Origin"); allowed[o] {
			w.Header().Set("Access-Control-Allow-Origin", o)
			w.Header().Set("Access-Control-Allow-Credentials", "true")
			w.Header().Set("Vary", "Origin")
			if r.Method == http.MethodOptions {
				w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE")
				w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
				w.WriteHeader(http.StatusNoContent)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}
