package httpx

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func spoolRequest(body string) (*httptest.ResponseRecorder, *http.Request) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("PUT", "/v1/blobs/x", strings.NewReader(body))
	return rec, req
}

func TestSpoolBodyReadsAndHashes(t *testing.T) {
	rec, req := spoolRequest("hello")
	sp, err := SpoolBody(rec, req, 10)
	if err != nil {
		t.Fatal(err)
	}
	defer sp.Close()
	sum := sha256.Sum256([]byte("hello"))
	if sp.Size != 5 || sp.SHA256 != hex.EncodeToString(sum[:]) {
		t.Fatalf("spool size %d sha %s", sp.Size, sp.SHA256)
	}
	rd, err := sp.Reader()
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(rd)
	if !bytes.Equal(got, []byte("hello")) {
		t.Fatalf("re-read %q", got)
	}
}

func TestSpoolBodyRejectsOversize(t *testing.T) {
	rec, req := spoolRequest("0123456789abc")
	if _, err := SpoolBody(rec, req, 10); !errors.Is(err, ErrBodyTooLarge) {
		t.Fatalf("want ErrBodyTooLarge, got %v", err)
	}
}

func TestSpoolBodyRejectsLyingContentLength(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("PUT", "/v1/blobs/x", strings.NewReader("too many bytes"))
	req.ContentLength = 1 // 声明的长度比实际小
	if _, err := SpoolBody(rec, req, 4); !errors.Is(err, ErrBodyTooLarge) {
		t.Fatalf("want ErrBodyTooLarge, got %v", err)
	}
}

func TestSpoolCloseRemovesFile(t *testing.T) {
	rec, req := spoolRequest("x")
	sp, err := SpoolBody(rec, req, 10)
	if err != nil {
		t.Fatal(err)
	}
	name := sp.file.Name()
	if err := sp.Close(); err != nil {
		t.Fatal(err)
	}
	if err := sp.Close(); err != nil {
		t.Fatalf("second Close must be a no-op: %v", err)
	}
	if _, err := os.Stat(name); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("temporary file %s should be removed, got %v", name, err)
	}
}

func TestValidSHA256(t *testing.T) {
	valid := strings.Repeat("a", 64)
	for _, tc := range []struct {
		in   string
		want bool
	}{
		{valid, true},
		{"0123456789abcdef" + strings.Repeat("0", 48), true},
		{"", false},
		{strings.Repeat("a", 63), false},
		{strings.Repeat("a", 65), false},
		{strings.ToUpper(valid), false},
		{"not-a-hash", false},
	} {
		if got := ValidSHA256(tc.in); got != tc.want {
			t.Errorf("ValidSHA256(%q) = %v, want %v", tc.in, got, tc.want)
		}
	}
}

// spoolRecorder 是一次 SpoolVerified 调用的结果。
func spoolRecorder(t *testing.T, body io.Reader, limit int64, want, tooLarge, mismatch string) (*httptest.ResponseRecorder, *Spool, bool) {
	t.Helper()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("PUT", "/v1/blobs/x", body)
	spool, ok := SpoolVerified(rec, req, slog.New(slog.NewTextHandler(io.Discard, nil)), SpoolCheck{
		Limit:    limit,
		SHA256:   want,
		TooLarge: tooLarge,
		Mismatch: mismatch,
	})
	return rec, spool, ok
}

func TestSpoolVerifiedAcceptsMatchingBody(t *testing.T) {
	sum := sha256.Sum256([]byte("hello"))
	want := hex.EncodeToString(sum[:])
	rec, spool, ok := spoolRecorder(t, strings.NewReader("hello"), 10, want, "too large", "mismatch")
	if !ok {
		t.Fatalf("valid body rejected: %d %s", rec.Code, rec.Body)
	}
	defer spool.Close()
	if spool.Size != 5 || spool.SHA256 != want {
		t.Fatalf("spool size %d sha %s", spool.Size, spool.SHA256)
	}
	if rec.Body.Len() != 0 {
		t.Fatalf("accepted body must not write a response: %q", rec.Body)
	}
}

func TestSpoolVerifiedRejectsOversize(t *testing.T) {
	rec, spool, ok := spoolRecorder(t, strings.NewReader("too many bytes"), 4, "", "attachment is too large", "mismatch")
	if ok || spool != nil {
		t.Fatal("oversize body accepted")
	}
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status %d, want 413", rec.Code)
	}
	assertProblemCode(t, rec, CodePayloadTooLarge, "attachment is too large")
}

func TestSpoolVerifiedRejectsHashMismatch(t *testing.T) {
	sum := sha256.Sum256([]byte("real-bytes"))
	claimed := hex.EncodeToString(sum[:])
	rec, spool, ok := spoolRecorder(t, strings.NewReader("other-bytes"), 100, claimed, "too large", "body does not match the sha256 in the path")
	if ok || spool != nil {
		t.Fatal("mismatched body accepted")
	}
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, want 400", rec.Code)
	}
	assertProblemCode(t, rec, CodeInvalidRequest, "body does not match the sha256 in the path")
}

func TestSpoolVerifiedReportsBodyReadError(t *testing.T) {
	rec, spool, ok := spoolRecorder(t, failingReader{}, 100, "", "too large", "mismatch")
	if ok || spool != nil {
		t.Fatal("unreadable body accepted")
	}
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, want 400", rec.Code)
	}
	assertProblemCode(t, rec, CodeInvalidRequest, "could not read body")
}

// failingReader 模拟读到一半连接断掉。
type failingReader struct{}

func (failingReader) Read([]byte) (int, error) { return 0, errors.New("connection reset") }

func assertProblemCode(t *testing.T, rec *httptest.ResponseRecorder, code Code, detail string) {
	t.Helper()
	if ct := rec.Header().Get("Content-Type"); ct != "application/problem+json" {
		t.Fatalf("content type %q", ct)
	}
	var p struct {
		Code   string `json:"code"`
		Detail string `json:"detail"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil {
		t.Fatalf("decode problem: %v", err)
	}
	if p.Code != string(code) {
		t.Fatalf("code %q, want %q", p.Code, code)
	}
	if p.Detail != detail {
		t.Fatalf("detail %q, want %q", p.Detail, detail)
	}
}
