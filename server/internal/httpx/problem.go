// Package httpx holds the HTTP conventions shared by every handler:
// RFC 9457 problem responses, JSON decoding with size limits, and middleware.
package httpx

import (
	"encoding/json"
	"net/http"
)

// Code is a program-defined error category. Clients branch on Code, never on
// the human-readable detail text. Keep this list in sync with api/openapi.yaml.
type Code string

const (
	CodeInvalidRequest     Code = "invalid_request"
	CodeUnauthorized       Code = "unauthorized"
	CodeInvalidCredentials Code = "invalid_credentials"
	CodeEmailTaken         Code = "email_taken"
	CodeNotFound           Code = "not_found"
	CodeConflict           Code = "conflict"
	CodePayloadTooLarge    Code = "payload_too_large"
	CodeModelNotAllowed    Code = "model_not_allowed"
	CodeQuotaExceeded      Code = "quota_exceeded"
	CodeUpstreamFailed     Code = "upstream_failed"
	CodeUnavailable        Code = "unavailable"
	CodeNotImplemented     Code = "not_implemented"
	CodeInternal           Code = "internal"
)

// Problem is an application/problem+json body (RFC 9457) with a "code"
// extension member.
type Problem struct {
	Type      string `json:"type"`
	Title     string `json:"title"`
	Status    int    `json:"status"`
	Code      Code   `json:"code"`
	Detail    string `json:"detail,omitempty"`
	RequestID string `json:"request_id,omitempty"`
	// Extra carries endpoint-specific members, e.g. the server head on a sync conflict.
	Extra map[string]any `json:"extra,omitempty"`
}

// WriteProblem writes a problem response. detail must never contain learning
// content, SQL, tokens or file paths: it may end up in client logs.
func WriteProblem(w http.ResponseWriter, r *http.Request, status int, code Code, detail string) {
	WriteProblemExtra(w, r, status, code, detail, nil)
}

// WriteProblemExtra is WriteProblem with extension members.
func WriteProblemExtra(w http.ResponseWriter, r *http.Request, status int, code Code, detail string, extra map[string]any) {
	p := Problem{
		Type:      "urn:zhixin:problem:" + string(code),
		Title:     http.StatusText(status),
		Status:    status,
		Code:      code,
		Detail:    detail,
		RequestID: RequestIDFrom(r.Context()),
		Extra:     extra,
	}
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(p)
}

// NotImplemented is a handler for routes that are in the contract but not built yet.
func NotImplemented(w http.ResponseWriter, r *http.Request) {
	WriteProblem(w, r, http.StatusNotImplemented, CodeNotImplemented, "this endpoint is part of the v1 contract but not implemented yet")
}
