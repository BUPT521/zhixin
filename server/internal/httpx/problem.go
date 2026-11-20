// Package httpx holds the HTTP conventions shared by every handler: RFC 9457
// problem responses, JSON decoding with size limits, and middleware.
package httpx

import (
	"encoding/json"
	"log/slog"
	"net/http"

	"github.com/BUPT521/zhixin/server/internal/api"
)

// Code is a program-defined error category. Clients branch on Code, never on
// the human-readable detail text. The values come from the generated contract
// enum so the server and api/openapi.yaml cannot drift apart.
type Code = api.ProblemCode

const (
	CodeInvalidRequest     = api.ProblemCodeInvalidRequest
	CodeUnauthorized       = api.ProblemCodeUnauthorized
	CodeInvalidCredentials = api.ProblemCodeInvalidCredentials
	CodeInvalidCode        = api.ProblemCodeInvalidCode
	CodeIdentifierTaken    = api.ProblemCodeIdentifierTaken
	CodeContactUnverified  = api.ProblemCodeContactUnverified
	CodeNotFound           = api.ProblemCodeNotFound
	CodeConflict           = api.ProblemCodeConflict
	CodePayloadTooLarge    = api.ProblemCodePayloadTooLarge
	CodeStorageFull        = api.ProblemCodeStorageFull
	CodeModelNotAllowed    = api.ProblemCodeModelNotAllowed
	CodeQuotaExceeded      = api.ProblemCodeQuotaExceeded
	CodeRateLimited        = api.ProblemCodeRateLimited
	CodeUpstreamFailed     = api.ProblemCodeUpstreamFailed
	CodeUnavailable        = api.ProblemCodeUnavailable
	CodeNotImplemented     = api.ProblemCodeNotImplemented
	CodeInternal           = api.ProblemCodeInternal
)

// WriteProblem writes an application/problem+json response. detail must never
// contain learning content, SQL, tokens or file paths: it may end up in client
// logs.
func WriteProblem(w http.ResponseWriter, r *http.Request, status int, code Code, detail string) {
	WriteProblemExtra(w, r, status, code, detail, nil)
}

// WriteProblemExtra is WriteProblem with endpoint-specific extension members,
// e.g. the server head on a sync conflict.
func WriteProblemExtra(w http.ResponseWriter, r *http.Request, status int, code Code, detail string, extra map[string]any) {
	p := api.Problem{
		Type:   "urn:zhixin:problem:" + string(code),
		Title:  http.StatusText(status),
		Status: status,
		Code:   code,
	}
	if detail != "" {
		p.Detail = &detail
	}
	if id := RequestIDFrom(r.Context()); id != "" {
		p.RequestId = &id
	}
	if extra != nil {
		p.Extra = &extra
	}
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(p)
}

// WriteInternal logs an unexpected error and answers with the generic 500
// problem. Handlers use this instead of writing their own log line and status,
// so every internal failure has the same body and the same log fields.
func WriteInternal(w http.ResponseWriter, r *http.Request, log *slog.Logger, err error) {
	log.Error("request failed",
		slog.String("request_id", RequestIDFrom(r.Context())),
		slog.String("route", r.Pattern),
		slog.String("error", err.Error()),
	)
	WriteProblem(w, r, http.StatusInternalServerError, CodeInternal, "")
}

// BindingErrorHandler turns a generated route's parameter binding failure into
// a problem response. Without it oapi-codegen falls back to a text/plain 400.
func BindingErrorHandler(w http.ResponseWriter, r *http.Request, err error) {
	WriteProblem(w, r, http.StatusBadRequest, CodeInvalidRequest, err.Error())
}
