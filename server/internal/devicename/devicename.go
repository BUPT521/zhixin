// Package devicename 统一清洗客户端上报的设备名。
//
// 备份入口的 X-Device-Name 与会话里的设备名是同一个展示字段，原来两处各写
// 一份清洗规则，超长时一处清空、一处截断。2026-11-27 定上限取 64 个字符，
// 两个入口共用这里的规则；契约里 X-Device-Name 的 maxLength 与它一致。
package devicename

import (
	"strings"
	"unicode/utf8"
)

// MaxLength 是设备名保留的最大字符数，按 rune 计。
const MaxLength = 64

// Clean 去掉首尾空白，超过 MaxLength 个字符时按字符截断，不整段置空；不是合法
// UTF-8 的输入按空串处理，避免把非法字节写进数据库与 JSON 响应。设备名只用于
// 展示，不参与鉴权与计费。
func Clean(name string) string {
	name = strings.TrimSpace(name)
	if !utf8.ValidString(name) {
		return ""
	}
	if utf8.RuneCountInString(name) > MaxLength {
		name = string([]rune(name)[:MaxLength])
	}
	return name
}
