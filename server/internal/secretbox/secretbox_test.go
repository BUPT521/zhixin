package secretbox

import (
	"encoding/base64"
	"errors"
	"strings"
	"testing"
)

func TestSealOpenRoundTrip(t *testing.T) {
	b := Random()
	sealed, err := b.Seal("sk-secret-1234", "p1")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(sealed, "v1:") || strings.Contains(sealed, "sk-secret") {
		t.Fatalf("密文格式不对或泄露了明文：%q", sealed)
	}
	again, _ := b.Seal("sk-secret-1234", "p1")
	if again == sealed {
		t.Fatal("同一明文两次加密应得到不同密文（随机 nonce）")
	}
	got, err := b.Open(sealed, "p1")
	if err != nil || got != "sk-secret-1234" {
		t.Fatalf("open: %q %v", got, err)
	}
	if _, err := b.Open(sealed, "p2"); !errors.Is(err, ErrUndecryptable) {
		t.Fatalf("附加数据不同时不能解密：%v", err)
	}
	if s, _ := b.Seal("", "p1"); s != "" {
		t.Fatalf("空字符串应保持为空，得到 %q", s)
	}
	if p, err := b.Open("", "p1"); p != "" || err != nil {
		t.Fatalf("空密文应得到空明文：%q %v", p, err)
	}
}

func TestOpenRejectsOtherKeyAndGarbage(t *testing.T) {
	sealed, _ := Random().Seal("sk-x", "a")
	for _, in := range []string{sealed, "v1:not-base64!", "plain", "v1:" + base64.StdEncoding.EncodeToString([]byte("short"))} {
		if _, err := Random().Open(in, "a"); !errors.Is(err, ErrUndecryptable) {
			t.Fatalf("%q: want ErrUndecryptable, got %v", in, err)
		}
	}
}

func TestParseKey(t *testing.T) {
	raw := make([]byte, 32)
	for i := range raw {
		raw[i] = byte(i * 7)
	}
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		key, err := ParseKey(" " + enc.EncodeToString(raw) + "\n")
		if err != nil || string(key) != string(raw) {
			t.Fatalf("%v: %v", enc, err)
		}
	}
	if _, err := ParseKey(base64.StdEncoding.EncodeToString(raw[:16])); err == nil {
		t.Fatal("16 字节应被拒绝")
	}
	if _, err := ParseKey("@@@"); err == nil {
		t.Fatal("非 base64 应被拒绝")
	}
}
