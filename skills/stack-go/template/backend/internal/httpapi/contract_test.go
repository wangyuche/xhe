package httpapi

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"

	"github.com/getkin/kin-openapi/openapi3"
	"github.com/getkin/kin-openapi/openapi3filter"
	"github.com/getkin/kin-openapi/routers"
	"github.com/getkin/kin-openapi/routers/gorillamux"

	"__MODULE__/internal/httpx"
)

// contractPath: CONTRACT_PATH env, default <repo>/api/openapi.yaml (this file is backend/internal/httpapi).
func contractPath() string {
	if p := os.Getenv("CONTRACT_PATH"); p != "" {
		return p
	}
	return filepath.Join("..", "..", "..", "api", "openapi.yaml")
}

func loadContract(t *testing.T) *openapi3.T {
	t.Helper()
	loader := openapi3.NewLoader()
	doc, err := loader.LoadFromFile(contractPath())
	if err != nil {
		t.Fatalf("load contract: %v", err)
	}
	if !strings.HasPrefix(doc.OpenAPI, "3.0") {
		t.Fatalf("contract must be OpenAPI 3.0.x, got %q", doc.OpenAPI)
	}
	if err := doc.Validate(loader.Context); err != nil {
		t.Fatalf("contract invalid: %v", err)
	}
	return doc
}

// TestContractRoutes: the route table and the contract must list the same "METHOD path".
// Operations marked `x-status: planned` may exist in the contract without a route.
func TestContractRoutes(t *testing.T) {
	doc := loadContract(t)

	inContract := map[string]bool{}
	planned := map[string]bool{}
	for path, item := range doc.Paths.Map() {
		for method, op := range item.Operations() {
			key := strings.ToUpper(method) + " " + path
			inContract[key] = true
			if s, ok := op.Extensions["x-status"]; ok && s == "planned" {
				planned[key] = true
			}
		}
	}
	inRoutes := map[string]bool{}
	for _, r := range Routes() {
		inRoutes[r.Method+" "+r.Pattern] = true
	}

	var problems []string
	for k := range inRoutes {
		if !inContract[k] {
			problems = append(problems, "route not in contract: "+k)
		} else if planned[k] {
			problems = append(problems, "implemented but still x-status: planned: "+k)
		}
	}
	for k := range inContract {
		if !inRoutes[k] && !planned[k] {
			problems = append(problems, "contract operation has no route (mark x-status: planned if not implemented yet): "+k)
		}
	}
	sort.Strings(problems)
	for _, p := range problems {
		t.Error(p)
	}
}

// ---- contract-checked request helpers for endpoint tests ----
// Endpoint tests live in internal/httpapi/*_test.go and call NewHandler(httpx.Deps{…}).

var (
	routerOnce sync.Once
	routerVal  routers.Router
	routerErr  error
)

func router(t *testing.T) routers.Router {
	t.Helper()
	routerOnce.Do(func() {
		loader := openapi3.NewLoader()
		doc, err := loader.LoadFromFile(contractPath())
		if err != nil {
			routerErr = err
			return
		}
		doc.Servers = openapi3.Servers{{URL: "http://example.com"}} // httptest default host
		routerVal, routerErr = gorillamux.NewRouter(doc)
	})
	if routerErr != nil {
		t.Fatalf("contract router: %v", routerErr)
	}
	return routerVal
}

// Do sends a request that must match the contract, and fails the test if the
// request or the response does not match. Use it for success cases and for
// error cases whose request is still contract-valid (e.g. wrong password → 401):
//
//	rec := Do(t, h, httptest.NewRequest("POST", "/api/login", strings.NewReader(body)))
func Do(t *testing.T, h http.Handler, req *http.Request) *httptest.ResponseRecorder {
	t.Helper()
	return do(t, h, req, false)
}

// DoBadRequest is for deliberately invalid requests (missing field, wrong type → 400).
// The request must NOT match the contract; the response still must.
func DoBadRequest(t *testing.T, h http.Handler, req *http.Request) *httptest.ResponseRecorder {
	t.Helper()
	return do(t, h, req, true)
}

func do(t *testing.T, h http.Handler, req *http.Request, expectInvalid bool) *httptest.ResponseRecorder {
	t.Helper()
	var reqBody []byte
	if req.Body != nil {
		reqBody, _ = io.ReadAll(req.Body)
		req.Body = io.NopCloser(bytes.NewReader(reqBody))
	}
	if req.Header.Get("Content-Type") == "" && len(reqBody) > 0 {
		req.Header.Set("Content-Type", "application/json")
	}

	route, params, err := router(t).FindRoute(req)
	if err != nil {
		t.Fatalf("%s %s: not in contract: %v", req.Method, req.URL.Path, err)
	}
	in := &openapi3filter.RequestValidationInput{
		Request: req, PathParams: params, Route: route,
		Options: &openapi3filter.Options{AuthenticationFunc: openapi3filter.NoopAuthenticationFunc},
	}
	ctx := context.Background()
	reqErr := openapi3filter.ValidateRequest(ctx, in)
	switch {
	case reqErr != nil && !expectInvalid:
		t.Errorf("%s %s: request does not match contract: %v", req.Method, req.URL.Path, reqErr)
	case reqErr == nil && expectInvalid:
		t.Errorf("%s %s: DoBadRequest used but the request is contract-valid", req.Method, req.URL.Path)
	}
	req.Body = io.NopCloser(bytes.NewReader(reqBody))

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	out := &openapi3filter.ResponseValidationInput{
		RequestValidationInput: in,
		Status:                 rec.Code,
		Header:                 rec.Header(),
		Options:                &openapi3filter.Options{IncludeResponseStatus: true},
	}
	out.SetBodyBytes(rec.Body.Bytes())
	if err := openapi3filter.ValidateResponse(ctx, out); err != nil {
		t.Errorf("%s %s → %d: response does not match contract: %v", req.Method, req.URL.Path, rec.Code, err)
	}
	return rec
}

func TestHealthz(t *testing.T) {
	h := NewHandler(httpx.Deps{})
	rec := Do(t, h, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("got %d", rec.Code)
	}
}
