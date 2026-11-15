package httpx

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
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
