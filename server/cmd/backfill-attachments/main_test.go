package main

import (
	"strings"
	"testing"
)

// TestParseAttachmentKey 守住回填命令解析对象键的规则：只认
// attachments/<账号>/<64 位小写十六进制>，临时文件、多余层级与别的业务对象都
// 跳过，避免把不相干的对象写进附件索引。
func TestParseAttachmentKey(t *testing.T) {
	sha := strings.Repeat("a", 64)

	user, got, ok := parseAttachmentKey("attachments/u1/" + sha)
	if !ok || user != "u1" || got != sha {
		t.Fatalf("valid key: user %q sha %q ok %v", user, got, ok)
	}

	for _, key := range []string{
		"",
		"attachments/",
		"attachments/u1",
		"attachments//" + sha,
		"backups/u1/b1.zip",
		"attachments/u1/../u2/" + sha,
		"attachments/u1/.part-123",
		"attachments/u1/" + strings.ToUpper(sha),
		"attachments/u1/" + sha + "/extra",
	} {
		if _, _, ok := parseAttachmentKey(key); ok {
			t.Errorf("key %q must be rejected", key)
		}
	}
}
