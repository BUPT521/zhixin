package auth

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"strings"
	"time"
	"unicode/utf8"
)

// 模型代理的接入密钥（ADR-0063）。密钥只用于 /v1/llm 下的模型接口，不参与登录，
// 也不持有学习数据；它与访问令牌共用 Authorization: Bearer 头，靠固定前缀与长度
// 区分，服务端因此不必先查一次会话表再判断类型。
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
	// apiKeyLength 是密钥的总长度：前缀加 24 字节的 base64 编码。
	apiKeyLength = len(APIKeyPrefix) + 32
)

// ErrKeyLimit 表示这个账号的密钥数已经达到上限。
var ErrKeyLimit = errors.New("auth: api key limit reached")

// LooksLikeAPIKey 报告一个 Bearer 凭据是否可能是模型代理密钥。判定看前缀与长度：
// 访问令牌是 32 字节随机数的 43 个字符，密钥是 35 个字符，随机生成的访问令牌因此
// 不会因为碰巧以 zx_ 开头被当成密钥。真正的校验在 AuthenticateAPIKey。
func LooksLikeAPIKey(token string) bool {
	return len(token) == apiKeyLength && strings.HasPrefix(token, APIKeyPrefix)
}

// newAPIKey 生成一把密钥并返回展示用的前缀。随机部分是 24 字节，密钥总长 35 个
// 字符，与 43 个字符的访问令牌不会混淆；整个密钥只在签发那一次返回，库里只存摘要。
func newAPIKey() (token, prefix string) {
	b := make([]byte, 24)
	_, _ = rand.Read(b)
	token = APIKeyPrefix + base64.RawURLEncoding.EncodeToString(b)
	return token, token[:apiKeyPrefixLength]
}

// CreateAPIKey 为当前账号签发一把模型代理密钥，返回明文密钥与记录。明文只在
// 这一次出现，库里只有 SHA-256。密钥没有有效期，只能显式撤销。
func (s *Service) CreateAPIKey(ctx context.Context, p Principal, name string) (APIKey, string, error) {
	name = strings.TrimSpace(name)
	if utf8.RuneCountInString(name) > maxKeyNameRunes {
		return APIKey{}, "", ErrInvalidInput
	}
	existing, err := s.store.KeysByUser(ctx, p.UserID)
	if err != nil {
		return APIKey{}, "", err
	}
	// 上限按仍然有效的密钥算，撤销一把之后可以再签发一把。并发签发时两个请求
	// 可能同时看到未满，实际最多多出一两把，这个偏差对容量没有影响。
	active := 0
	for _, key := range existing {
		if !key.Revoked {
			active++
		}
	}
	if active >= maxKeysPerUser {
		return APIKey{}, "", ErrKeyLimit
	}
	token, prefix := newAPIKey()
	key := APIKey{
		ID: newID(), UserID: p.UserID, Name: name, Prefix: prefix,
		CreatedAt: s.now(),
	}
	if err := s.store.CreateKey(ctx, key, hashToken(token)); err != nil {
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
	// 最近使用时间只用于辨认，写不进去不影响这次请求。
	_ = s.store.TouchKey(ctx, key.ID)
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
