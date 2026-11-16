// Package httpx holds what every handler package shares: dependencies and
// JSON / error helpers. Domain packages (internal/auth, internal/order, …)
// import httpx; internal/httpapi imports the domain packages. No cycles.
package httpx

import (
	"database/sql"
	"encoding/json"
	"log/slog"
	"net/http"
)

// Deps are passed to every handler constructor: func(httpx.Deps) http.HandlerFunc.
type Deps struct {
	DB     *sql.DB
	Logger *slog.Logger
}

// APIError is the only error body format: {"error":{"code":"…","message":"…"}}.
type APIError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// WriteError writes {"error":{"code","message"}}. code is snake_case, e.g. "validation_failed".
func WriteError(w http.ResponseWriter, status int, code, message string) {
	WriteJSON(w, status, map[string]APIError{"error": {Code: code, Message: message}})
}
