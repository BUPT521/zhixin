// Package deref 提供泛型解引用：指针为空时返回调用方给出的兜底值。
package deref

import "testing"

func TestValueReturnsThePointedValueOrDefault(t *testing.T) {
	value := 7
	if got := Value(&value, 0); got != 7 {
		t.Fatalf("应返回指针指向的值，得到 %d", got)
	}
	if got := Value[int](nil, 0); got != 0 {
		t.Fatalf("空指针应返回兜底值，得到 %d", got)
	}
	if got := Value[string](nil, "兜底"); got != "兜底" {
		t.Fatalf("空指针应返回兜底值，得到 %q", got)
	}
	empty := ""
	if got := Value(&empty, "兜底"); got != "" {
		t.Fatalf("指向空值时应返回空值本身，得到 %q", got)
	}
}
