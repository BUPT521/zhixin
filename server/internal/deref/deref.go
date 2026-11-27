// Package deref 提供泛型解引用：指针为空时返回调用方给出的兜底值。
//
// 管理后台读请求体里的可选字段时都要做这一步，账号、反馈与模型代理三个后台原本各写
// 一份实现；实现放在这里，调用方只保留兜底值本身的业务含义。
package deref

// Value 返回指针指向的值，value 为空时返回 fallback。
func Value[T any](value *T, fallback T) T {
	if value == nil {
		return fallback
	}
	return *value
}
