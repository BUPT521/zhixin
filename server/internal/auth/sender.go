package auth

import (
	"context"
	"errors"
	"time"
)

// ErrSenderUnsupported 表示这种登录方式还没有接上发送通道：手机号要接短信服务商，
// 微信要接开放平台，两者都还没有做（ADR-0038）。接口据此回 501 暂不支持，与
// “通道配置缺失”的 503 分开。
var ErrSenderUnsupported = errors.New("auth: no sender for this identity kind")

// ErrMailPaused 表示发信通道因为连续被服务商拒绝而整体暂停，暂停时长由发信器
// 决定。它与“没有配置发信”不同：暂停期间请求返回 429 并给出迟一些再试的秒数，
// 而不是 503。
var ErrMailPaused = errors.New("auth: mail sender is paused after repeated temporary failures")

// mailPauseError 是暂停期间发信返回的错误，带上还要等待的整秒数。errors.Is 对它
// 判定 ErrMailPaused 成立，处理器再按 errors.As 取出等待时长写成 429 的
// Retry-After，而不是把暂停误报成“没有配置发信”的 503。
type mailPauseError struct{ retryAfter int64 }

func (e mailPauseError) Error() string {
	return "auth: 发信暂缓 " + (time.Duration(e.retryAfter) * time.Second).String() + " 后重试"
}

// Is 让 errors.Is(err, ErrMailPaused) 成立。
func (mailPauseError) Is(target error) bool { return target == ErrMailPaused }

// mailPauser 是发信器可选实现的接口，返回还要暂停多久；0 表示可以继续发。
type mailPauser interface {
	PausedFor() time.Duration
}

// PausedFor 报告发信是否处于暂停，供服务层在生成验证码之前就拒绝。
func (s *Senders) PausedFor() time.Duration {
	if s == nil || s.mail == nil {
		return 0
	}
	if p, ok := s.mail.(mailPauser); ok {
		return p.PausedFor()
	}
	return 0
}

// CodeSender 按登录方式分发验证码，由各通道根据用途和有效期生成正文。
type CodeSender interface {
	// CanSend 报告这种登录方式现在有没有装好的发送通道；服务层据此在写验证码之前
	// 就拒绝，不留下一条用不上的记录。
	CanSend(kind string) bool
	// SendCode 把一条验证码交给对应的通道。
	SendCode(ctx context.Context, kind, identifier, purpose, code string, ttl time.Duration) error
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

func (s *Senders) SendCode(ctx context.Context, kind, identifier, purpose, code string, ttl time.Duration) error {
	switch kind {
	case KindEmail:
		if s == nil || s.mail == nil {
			return ErrMailUnavailable
		}
		message, err := renderCodeEmail(purpose, code, ttl)
		if err != nil {
			return err
		}
		return s.mail.Send(ctx, identifier, message)
	default:
		return ErrSenderUnsupported
	}
}
