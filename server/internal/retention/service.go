package retention

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"log/slog"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/BUPT521/zhixin/server/internal/periodic"
)

// Ping 是处理器从请求里取出、还没校验的一条匿名上报。
type Ping struct {
	InstallID  string
	AppVersion string
	Platform   string
}

// Service 校验匿名上报、算安装标识的哈希并写入存储；同一个账号的活跃按天
// 去重，避免每个请求都写一次库。
type Service struct {
	store  Store
	secret []byte
	loc    *time.Location
	now    func() time.Time

	mu          sync.Mutex
	lastUserDay map[string]string
}

func NewService(store Store, secret []byte, loc *time.Location) *Service {
	if loc == nil {
		loc = time.UTC
	}
	return &Service{
		store:       store,
		secret:      append([]byte(nil), secret...),
		loc:         loc,
		now:         time.Now,
		lastUserDay: map[string]string{},
	}
}

// RecordInstall 校验并保存一次匿名活跃。服务端自己决定日期，不使用客户端时钟：
// 本机时间错了也不该把统计挪到另一天。同一个标识同一天重复上报由存储幂等处理，
// 客户端丢失响应后原样重试是安全的。
func (s *Service) RecordInstall(ctx context.Context, ping Ping) error {
	hash, err := s.hashInstall(ping.InstallID)
	if err != nil {
		return err
	}
	version, err := cleanField(ping.AppVersion, maxVersionRunes)
	if err != nil {
		return err
	}
	platform, err := cleanField(ping.Platform, maxPlatformRunes)
	if err != nil {
		return err
	}
	return s.store.MarkInstallActive(ctx, hash, s.today(), version, platform)
}

// RecordUserActive 满足 auth.ActivityRecorder 的接口：同一天同一个账号只在第一次
// 调用时写库，之后的请求只读一次内存表。写失败不缓存，下一个请求会再试。
func (s *Service) RecordUserActive(ctx context.Context, userID string) error {
	day := s.today()
	s.mu.Lock()
	written := s.lastUserDay[userID] == day
	s.mu.Unlock()
	if written {
		return nil
	}
	if err := s.store.MarkUserActive(ctx, userID, day); err != nil {
		return err
	}
	s.mu.Lock()
	s.lastUserDay[userID] = day
	s.mu.Unlock()
	return nil
}

// Prune 删除保留期之外的匿名活跃，见 ADR-0019 第 4 条。
func (s *Service) Prune(ctx context.Context) error {
	return Prune(ctx, s.store, s.loc, s.now())
}

func (s *Service) today() string { return dayOf(s.now(), s.loc) }

// hashInstall 校验安装标识的格式并算 HMAC-SHA256。只接受字母、数字、短横线与
// 下划线，这样客户端发来的随机串不会夹带别的信息；原始标识不落库。
func (s *Service) hashInstall(raw string) (string, error) {
	id := strings.TrimSpace(raw)
	if !utf8.ValidString(id) {
		return "", ErrInvalid
	}
	if n := utf8.RuneCountInString(id); n < minInstallRunes || n > maxInstallRunes {
		return "", ErrInvalid
	}
	for _, r := range id {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
		default:
			return "", ErrInvalid
		}
	}
	mac := hmac.New(sha256.New, s.secret)
	_, _ = mac.Write([]byte(id))
	return hex.EncodeToString(mac.Sum(nil)), nil
}

// cleanField 去掉附带字段两端的空白，超长或不合法的 UTF-8 一律拒绝：静默截断
// 会让上报内容与客户端以为的不一样。
func cleanField(raw string, max int) (string, error) {
	value := strings.TrimSpace(raw)
	if !utf8.ValidString(value) || utf8.RuneCountInString(value) > max {
		return "", ErrInvalid
	}
	return value, nil
}

// Prune 按配置时区算出保留期的起点，删除更早的匿名活跃。单独导出是为了让
// 启动与每日清理共用同一段计算。
func Prune(ctx context.Context, store Store, loc *time.Location, now time.Time) error {
	if loc == nil {
		loc = time.UTC
	}
	before := dayOf(now.AddDate(0, 0, -ActiveKeepDays), loc)
	return store.PruneInstallsBefore(ctx, before)
}

// PruneLoop 在启动时清理一次，之后每天清理一次，直到 ctx 结束。进程重启不会
// 让数据超过保留期；每天一次的频率对这张表足够，不需要更细的定时。
func PruneLoop(ctx context.Context, store Store, loc *time.Location, log *slog.Logger) {
	prune := func() {
		if err := Prune(ctx, store, loc, time.Now()); err != nil {
			log.Error("prune anonymous activity", slog.String("error", err.Error()))
		}
	}
	periodic.Run(ctx, time.Hour*24, prune)
}
