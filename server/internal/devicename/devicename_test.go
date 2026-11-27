package devicename

import (
	"strings"
	"testing"
)

func TestClean(t *testing.T) {
	overlong := strings.Repeat("备", MaxLength+6)
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"去首尾空白", "  phone  ", "phone"},
		{"恰好上限", strings.Repeat("a", MaxLength), strings.Repeat("a", MaxLength)},
		// 超长按字符截断，不是整段置空；中文按 rune 计，不能按字节截断。
		{"超长截断", overlong, strings.Repeat("备", MaxLength)},
		{"空串", "", ""},
		{"非法 UTF-8 置空", "a\xffb", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := Clean(tc.in)
			if got != tc.want {
				t.Fatalf("Clean(%q) = %q，want %q", tc.in, got, tc.want)
			}
		})
	}
}
