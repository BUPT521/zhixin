package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"strings"
	"time"
	"unicode/utf8"
)

// 模型代理的接入密钥（ADR-0063）。密钥只用于 /v1/llm 下的模型接口，不参与登录，
// 也不持有学习数据；它与访问令牌共用 Authorization: Bearer 头，靠固定前缀、长度与
// 末尾校验码区分，服务端因此不必先查一次会话表再判断类型。
const (
	// APIKeyPrefix 是密钥的固定前缀，也是与访问令牌区分的依据。
	APIKeyPrefix = "zx_"
	// apiKeyPrefixLength 是列表里展示的前缀长度：zx_ 加 8 位随机字符。
	apiKeyPrefixLength = len(APIKeyPrefix) + 8
	// maxKeysPerUser 是每个账号最多保留的有效密钥数。上限只限定同时可用的凭据
	// 与列表长度，不是安全边界；撤销一把之后可以再签一把，已撤销的行不占额度，
	// 由每日清理在保留期之后删掉。
	maxKeysPerUser = 20
	// revokedKeyKeep 是已撤销密钥行的保留期。列表只需要看最近的撤销记录，行留着
	// 只会让表随反复签发与撤销无限变长；超过这段保留期的行由每夜清理删除，与
	// 其他保留期一样按服务端时钟算。
	revokedKeyKeep = 30 * 24 * time.Hour
	// maxKeyNameRunes 是密钥名字的长度上限，名字只用于辨认，不参与鉴权。
	maxKeyNameRunes = 64
	// apiKeyRandomLength 是随机部分的字符数：24 字节的 base64url。
	apiKeyRandomLength = 32
	// apiKeyChecksumLength 是末尾校验码的字符数：SHA-256 前 3 字节的 base64url。
	apiKeyChecksumLength = 4
	// apiKeyLength 是密钥的总长度：前缀、随机部分与校验码，共 39 个字符。
	apiKeyLength = len(APIKeyPrefix) + apiKeyRandomLength + apiKeyChecksumLength
	// keyTouchInterval 是进程内跳过最近使用时间写库的间隔，与存储层条件更新的
	// 十分钟粒度一致。
	keyTouchInterval = 10 * time.Minute
	// keyTouchCacheMax 是进程内记录的上限。达到之后整表清空，之后每一次使用重写
	// 一次，记录不会随用过的密钥数量无限变大。
	keyTouchCacheMax = 4096
)

// ErrKeyLimit 表示这个账号的密钥数已经达到上限。
var ErrKeyLimit = errors.New("auth: api key limit reached")

// LooksLikeAPIKey 报告一个 Bearer 凭据是否可能是模型代理密钥。判定看前缀、长度
// 与末尾校验码：访问令牌是 32 字节随机数的 43 个字符，密钥是 39 个字符，随机生成
// 的访问令牌因此不会因为碰巧以 zx_ 开头被当成密钥；校验码对不上的串在查库之前
// 就按无效凭据拒掉。真正的校验在 AuthenticateAPIKey。
func LooksLikeAPIKey(token string) bool {
	if len(token) != apiKeyLength || !strings.HasPrefix(token, APIKeyPrefix) {
		return false
	}
	body := token[:len(token)-apiKeyChecksumLength]
	return subtle.ConstantTimeCompare([]byte(apiKeyChecksum(body)), []byte(token[len(body):])) == 1
}

// newAPIKey 生成一把密钥并返回展示用的前缀。随机部分是 24 字节，末尾 4 个字符是
// 对前面的部分算出的校验码，整个密钥共 39 个字符，与 43 个字符的访问令牌不会混淆；
// 整个密钥只在签发那一次返回，库里只存摘要。
func newAPIKey() (token, prefix string) {
	b := make([]byte, 24)
	_, _ = rand.Read(b)
	body := APIKeyPrefix + base64.RawURLEncoding.EncodeToString(b)
	token = body + apiKeyChecksum(body)
	return token, token[:apiKeyPrefixLength]
}

// apiKeyChecksum 返回一段密钥的校验码：对前缀与随机部分算 SHA-256，取前 3 字节做
// base64url，正好 4 个字符。它只用于识别形状与拦截写错的串，不承担密钥强度。
func apiKeyChecksum(body string) string {
	sum := sha256.Sum256([]byte(body))
	return base64.RawURLEncoding.EncodeToString(sum[:3])
}

// keyTouchDue 报告这把密钥是否需要尝试写一次最近使用时间，并记下这次尝试的时刻。
// 记录在进程内，多实例部署时各实例各记一份：存储层的条件更新仍然是最终频率约束。
func (s *Service) keyTouchDue(id string) bool {
	s.keyTouchMu.Lock()
	defer s.keyTouchMu.Unlock()
	if s.keyTouch == nil {
		s.keyTouch = map[string]time.Time{}
	}
	now := s.now()
	if last, ok := s.keyTouch[id]; ok && now.Sub(last) < keyTouchInterval {
		return false
	}
	if len(s.keyTouch) >= keyTouchCacheMax {
		clear(s.keyTouch)
	}
	s.keyTouch[id] = now
	return true
}

// CreateAPIKey 为当前账号签发一把模型代理密钥，返回明文密钥与记录。明文只在
// 这一次出现，库里只有 SHA-256。密钥没有有效期，只能显式撤销。是否达到每个账号
// 的有效密钥上限由存储层在写入时一起判定：先读出全部密钥再在 Go 里计数的话，
// 并发签发会各自按旧计数通过，上限因此被突破。
func (s *Service) CreateAPIKey(ctx context.Context, p Principal, name string) (APIKey, string, error) {
	name = strings.TrimSpace(name)
	if utf8.RuneCountInString(name) > maxKeyNameRunes {
		return APIKey{}, "", ErrInvalidInput
	}
	token, prefix := newAPIKey()
	key := APIKey{
		ID: newID(), UserID: p.UserID, Name: name, Prefix: prefix,
		CreatedAt: s.now(),
	}
	if err := s.store.CreateKey(ctx, key, hashToken(token), maxKeysPerUser); err != nil {
		return APIKey{}, "", err
	}
	return key, token, nil
}

// APIKeys 按创建时间倒序列出当前账号的密钥，包括已经撤销的。
func (s *Service) APIKeys(ctx context.Context, p Principal) ([]APIKey, error) {
	return s.store.KeysByUser(ctx, p.UserID)
}

// RevokeAPIKey 撤销当前账号名下的一把密钥；不存在、已经撤销或属于别的账号时
// 返回 ErrNotFound。
func (s *Service) RevokeAPIKey(ctx context.Context, p Principal, id string) error {
	return s.store.RevokeKey(ctx, p.UserID, id)
}

// AuthenticateAPIKey 按摘要解析一把密钥。已经撤销的密钥按无效处理，与访问令牌
// 的 ErrInvalidToken 同一结果；存储故障原样返回，由中间件区分 401 与 500。
func (s *Service) AuthenticateAPIKey(ctx context.Context, token string) (Principal, error) {
	if !LooksLikeAPIKey(token) {
		return Principal{}, ErrInvalidToken
	}
	key, err := s.store.KeyByHash(ctx, hashToken(token))
	if errors.Is(err, ErrNotFound) {
		return Principal{}, ErrInvalidToken
	}
	if err != nil {
		return Principal{}, err
	}
	// 最近使用时间只用于辨认，写不进去不影响这次请求；十分钟内重复使用同一把
	// 密钥时不再访问数据库。
	if s.keyTouchDue(key.ID) {
		_ = s.store.TouchKey(ctx, key.ID)
	}
	return Principal{
		UserID:          key.UserID,
		KeyID:           key.ID,
		ContactVerified: key.ContactVerified,
	}, nil
}

// RevokeAllAPIKeys 撤销当前账号名下所有仍然有效的密钥，返回撤销的条数。已经
// 撤销的行保留原样；重设密码时存储层做同一件事。
func (s *Service) RevokeAllAPIKeys(ctx context.Context, p Principal) (int64, error) {
	return s.store.RevokeAllKeys(ctx, p.UserID)
}
