package httpx

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
)

// DecodeJSON reads one JSON object from the request body into dst. It rejects
// bodies over maxBytes, unknown fields and trailing data, and writes the
// problem response itself; callers just return when ok is false.
func DecodeJSON(w http.ResponseWriter, r *http.Request, maxBytes int64, dst any) (ok bool) {
	r.Body = http.MaxBytesReader(w, r.Body, maxBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			WriteProblem(w, r, http.StatusRequestEntityTooLarge, CodePayloadTooLarge, fmt.Sprintf("body exceeds %d bytes", maxBytes))
			return false
		}
		WriteProblem(w, r, http.StatusBadRequest, CodeInvalidRequest, "body is not a valid JSON object for this endpoint")
		return false
	}
	if _, err := dec.Token(); err != io.EOF {
		WriteProblem(w, r, http.StatusBadRequest, CodeInvalidRequest, "body must contain exactly one JSON object")
		return false
	}
	return true
}

// WriteJSON writes v as a JSON response with the given status.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
