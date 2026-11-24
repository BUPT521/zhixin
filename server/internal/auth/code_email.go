package auth

import (
	"bytes"
	_ "embed"
	"fmt"
	"html/template"
	"time"
)

//go:embed code_email.html
var codeEmailHTML string

var codeEmailTemplate = template.Must(template.New("code_email").Parse(codeEmailHTML))

func renderCodeEmail(purpose, code string, ttl time.Duration) (MailMessage, error) {
	title, action := "验证邮箱", "确认邮箱"
	if purpose == PurposeResetPassword {
		title, action = "重设密码", "重设密码"
	}

	content := struct {
		Title, Instruction, Code, Expiry, Footer string
	}{
		Title:       title,
		Instruction: "在知新输入验证码，" + action + "。",
		Code:        code,
		Expiry:      fmt.Sprintf("验证码在 %d 分钟内有效。", max(1, int(ttl/time.Minute))),
		Footer:      "如果你未发起此操作，可忽略这封邮件。请勿向他人透露验证码。",
	}
	var html bytes.Buffer
	if err := codeEmailTemplate.Execute(&html, content); err != nil {
		return MailMessage{}, fmt.Errorf("auth: 生成验证码邮件失败: %w", err)
	}
	return MailMessage{
		Subject: "知新 · " + title + "验证码",
		Text:    fmt.Sprintf("%s\n\n%s\n\n验证码：%s\n%s\n\n%s\n", title, content.Instruction, code, content.Expiry, content.Footer),
		HTML:    html.String(),
	}, nil
}
