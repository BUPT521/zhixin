package adminlist

import (
	"errors"
	"strings"
	"testing"
)

// TestLimitTakesTheDefaultAndRejectsOutOfRange 守住每页条数的口径：不传时用默认值，
// 0 与超过上限都拒绝，不悄悄截断。
func TestLimitTakesTheDefaultAndRejectsOutOfRange(t *testing.T) {
	for _, tc := range []struct {
		name  string
		value *int
		want  int
	}{
		{"缺省", nil, DefaultLimit},
		{"下限", intPointer(1), 1},
		{"上限", intPointer(MaxLimit), MaxLimit},
	} {
		got, err := Limit(tc.value)
		if err != nil || got != tc.want {
			t.Errorf("%s: Limit = %d, %v，应为 %d", tc.name, got, err, tc.want)
		}
	}
	for _, value := range []int{0, -1, MaxLimit + 1} {
		if got, err := Limit(intPointer(value)); !errors.Is(err, ErrLimit) || got != 0 {
			t.Errorf("Limit(%d) = %d, %v，应为 0, ErrLimit", value, got, err)
		}
	}
	if got := ErrLimit.Error(); !strings.Contains(got, "100") {
		t.Fatalf("上限文案应带出 MaxLimit，得到 %q", got)
	}
}

// TestOffsetTakesTheDefaultAndRejectsOutOfRange 守住偏移的口径：不传时为零，负数与
// 超过上限都拒绝。
func TestOffsetTakesTheDefaultAndRejectsOutOfRange(t *testing.T) {
	if got, err := Offset(nil); err != nil || got != 0 {
		t.Fatalf("不传偏移应为 0: %d, %v", got, err)
	}
	for _, value := range []int{0, MaxOffset} {
		if got, err := Offset(intPointer(value)); err != nil || got != value {
			t.Errorf("Offset(%d) = %d, %v", value, got, err)
		}
	}
	for _, value := range []int{-1, MaxOffset + 1} {
		if got, err := Offset(intPointer(value)); !errors.Is(err, ErrOffset) || got != 0 {
			t.Errorf("Offset(%d) = %d, %v，应为 0, ErrOffset", value, got, err)
		}
	}
	if got := ErrOffset.Error(); !strings.Contains(got, "100000") {
		t.Fatalf("偏移文案应带出 MaxOffset，得到 %q", got)
	}
}

// TestQueryCountsRunesNotBytes 守住搜索词按字符数校验：254 个汉字合法，255 个拒绝。
func TestQueryCountsRunesNotBytes(t *testing.T) {
	if err := Query(strings.Repeat("知", MaxQuery)); err != nil {
		t.Fatalf("%d 个汉字应当合法: %v", MaxQuery, err)
	}
	if err := Query(strings.Repeat("知", MaxQuery+1)); !errors.Is(err, ErrQuery) {
		t.Fatalf("超过 %d 个字符应当拒绝: %v", MaxQuery, err)
	}
}

func intPointer(value int) *int { return &value }
