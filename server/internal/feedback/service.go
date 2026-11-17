package feedback

import (
	"context"
	"net/mail"
	"strings"
	"time"
	"unicode/utf8"
)

// 反馈各字段的上限。正文限 4000 字，够写清一次问题；诊断摘要是客户端从本机
// 诊断记录里截取的片段，限 64 KiB 量级，不让它变成第二份数据上传。上限写在
// 代码里而不是配置里：客户端按契约填，服务端换个实例也不应忽然拒收。
const (
	MaxContentRunes     = 4000
	MaxDiagnosticsRunes = 65536
	MaxAppVersionRunes  = 64
	MaxPlatformRunes    = 32
	MaxContactBytes     = 254
)

// Submission 是处理器从请求里取出、还没校验的一条反馈。
type Submission struct {
	Content     string
	Contact     string
	AppVersion  string
	Platform    string
	Diagnostics string
}

// Receipt 是保存成功之后返回给客户端的回执。
type Receipt struct {
	ID        string
	CreatedAt time.Time
}

// Service 负责字段校验与编号；处理器只管 HTTP，存储只管保存。
type Service struct {
	store Store
	now   func() time.Time
}

func NewService(store Store) *Service {
	return &Service{store: store, now: time.Now}
}

// Submit 校验并保存一条反馈。任何字段不合格都返回 ErrInvalidInput，客户端
// 据此提示用户修改；存储失败原样上抛，由处理器按内部错误处理。
func (s *Service) Submit(ctx context.Context, sub Submission) (Receipt, error) {
	item, err := prepare(sub)
	if err != nil {
		return Receipt{}, err
	}
	item.ID = newID()
	item.CreatedAt = s.now().UTC()
	if err := s.store.CreateFeedback(ctx, item); err != nil {
		return Receipt{}, err
	}
	return Receipt{ID: item.ID, CreatedAt: item.CreatedAt}, nil
}

// prepare 做纯校验与规范化，不碰存储，方便单独核对边界。
func prepare(sub Submission) (Item, error) {
	content := strings.TrimSpace(sub.Content)
	if !utf8.ValidString(content) {
		return Item{}, ErrInvalidInput
	}
	if n := utf8.RuneCountInString(content); n < 1 || n > MaxContentRunes {
		return Item{}, ErrInvalidInput
	}
	contact, err := cleanContact(sub.Contact)
	if err != nil {
		return Item{}, err
	}
	appVersion := strings.TrimSpace(sub.AppVersion)
	if !utf8.ValidString(appVersion) || utf8.RuneCountInString(appVersion) > MaxAppVersionRunes {
		return Item{}, ErrInvalidInput
	}
	platform := strings.TrimSpace(sub.Platform)
	if !utf8.ValidString(platform) || utf8.RuneCountInString(platform) > MaxPlatformRunes {
		return Item{}, ErrInvalidInput
	}
	diagnostics := strings.TrimSpace(sub.Diagnostics)
	if !utf8.ValidString(diagnostics) || utf8.RuneCountInString(diagnostics) > MaxDiagnosticsRunes {
		return Item{}, ErrInvalidInput
	}
	return Item{
		Content:     content,
		Contact:     contact,
		AppVersion:  appVersion,
		Platform:    platform,
		Diagnostics: diagnostics,
	}, nil
}

// cleanContact 接受空值与一个普通邮箱地址。规则与注册一致：转小写、只用地址
// 本身；契约层把带显示名的写法解析成地址之后再进来，这里再核对一遍，直接调用
// 服务层时也不接受显示名。不合法时让整条反馈失败，客户端应提示用户改邮箱再提交，
// 不能悄悄丢掉用户写的联系地址。
func cleanContact(raw string) (string, error) {
	contact := strings.ToLower(strings.TrimSpace(raw))
	if contact == "" {
		return "", nil
	}
	addr, err := mail.ParseAddress(contact)
	if err != nil || addr.Address != contact || len(contact) > MaxContactBytes {
		return "", ErrInvalidInput
	}
	return contact, nil
}
