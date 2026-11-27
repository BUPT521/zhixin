// Package adminlist 是管理后台列表接口共用的分页口径：默认条数、一页上限、偏移上限
// 与搜索词长度只在这里定义，越界时返回的文案也由这里给出，账号与反馈两个后台引用
// 同一份，改上限时不用再改另一处字面量。
package adminlist

import (
	"errors"
	"fmt"
	"unicode/utf8"
)

const (
	// DefaultLimit 是不传 limit 时返回的条数。
	DefaultLimit = 20
	// MaxLimit 是一页最多返回的条数。
	MaxLimit = 100
	// MaxOffset 是允许的最大偏移，避免翻页翻得太深把查询拖慢。
	MaxOffset = 100000
	// MaxQuery 是搜索词的最大字符数。
	MaxQuery = 254
)

// 越界文案。上限变化时由上面的常量带出新的数字，调用方不再各写一份字面量。
var (
	ErrLimit  = fmt.Errorf("limit: 1 to %d", MaxLimit)
	ErrOffset = fmt.Errorf("offset: 0 to %d", MaxOffset)
	ErrQuery  = errors.New("query is too long")
)

// Limit 返回校验后的每页条数：缺省取 DefaultLimit，越界返回 ErrLimit。
func Limit(value *int) (int, error) {
	if value == nil {
		return DefaultLimit, nil
	}
	if *value < 1 || *value > MaxLimit {
		return 0, ErrLimit
	}
	return *value, nil
}

// Offset 返回校验后的偏移：缺省为零，越界返回 ErrOffset。
func Offset(value *int) (int, error) {
	if value == nil {
		return 0, nil
	}
	if *value < 0 || *value > MaxOffset {
		return 0, ErrOffset
	}
	return *value, nil
}

// Query 校验搜索词的长度，超过 MaxQuery 个字符时返回 ErrQuery；整理空白由调用方做。
func Query(value string) error {
	if utf8.RuneCountInString(value) > MaxQuery {
		return ErrQuery
	}
	return nil
}
