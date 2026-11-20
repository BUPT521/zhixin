package auth

import (
	"context"
	"errors"
)

// ErrSenderUnsupported 表示这种登录方式还没有接上发送通道：手机号要接短信服务商，
// 微信要接开放平台，两者都还没有做（ADR-0038）。接口据此回 501 暂不支持，与
// “通道配置缺失”的 503 分开。
var ErrSenderUnsupported = errors.New("auth: no sender for this identity kind")

// CodeSender 按登录方式分发验证码：验证码文本由服务层生成，送达方式按 kind
// 不同。以后接手机号或微信，只要实现一个同样签名的发送函数并在 Senders 里登记，
// 服务层与库表都不用改。
type CodeSender interface {
	// CanSend 报告这种登录方式现在有没有装好的发送通道；服务层据此在写验证码之前
	// 就拒绝，不留下一条用不上的记录。
	CanSend(kind string) bool
	// SendCode 把一条验证码交给对应的通道。
	SendCode(ctx context.Context, kind, identifier, subject, body string) error
}

// Senders 是现在唯一装配好的分发实现：邮箱走 Mailer，其余登录方式返回
// ErrSenderUnsupported。Mailer 只管一种通道，认不认识 kind 由这里判断。
type Senders struct {
	mail Mailer
}

// NewSenders 装上按 kind 分发的发送实现；mail 为空时邮箱也发不出去，请求返回
// ErrMailUnavailable。
func NewSenders(mail Mailer) *Senders { return &Senders{mail: mail} }

// CanSend 报告这种登录方式现在有没有装好的发送通道：邮箱要求 Mailer 非空，其余
// 种类都还没有接。服务层据此在写验证码之前就拒绝，不留下用不上的行。
func (s *Senders) CanSend(kind string) bool {
	switch kind {
	case KindEmail:
		return s != nil && s.mail != nil
	default:
		return false
	}
}

func (s *Senders) SendCode(ctx context.Context, kind, identifier, subject, body string) error {
	switch kind {
	case KindEmail:
		if s == nil || s.mail == nil {
			return ErrMailUnavailable
		}
		return s.mail.Send(ctx, identifier, subject, body)
	default:
		return ErrSenderUnsupported
	}
}
