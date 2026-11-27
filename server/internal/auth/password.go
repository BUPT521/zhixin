package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"

	"golang.org/x/crypto/argon2"
)

// argon2id parameters follow the OWASP minimum (19 MiB, t=2, p=1). They are
// encoded into every hash, so raising them later only affects new hashes.
// argonMemoryKiB 是单次哈希占用的内存，密码预算用的 MiB 数由它换算（budget.go）。
const (
	argonMemoryKiB = 19 * 1024
	argonTime      = 2
	argonThreads   = 1
	argonKeyLen    = 32
	argonSaltLen   = 16
)

var b64 = base64.RawStdEncoding

// HashPassword returns a PHC-formatted argon2id hash.
func HashPassword(password string) (string, error) {
	salt := make([]byte, argonSaltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key := argon2.IDKey([]byte(password), salt, argonTime, argonMemoryKiB, argonThreads, argonKeyLen)
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, argonMemoryKiB, argonTime, argonThreads, b64.EncodeToString(salt), b64.EncodeToString(key)), nil
}

var errBadHash = errors.New("auth: malformed password hash")

// 校验库里哈希时的参数上限。哈希由服务端按 argonMemoryKiB 那组参数写入，正常
// 不会越界；一旦库里出现几百 MiB 或几万次迭代的哈希（改库、导入旧数据、被写入
// 异常值），一次登录就能占满内存与 CPU，所以在计算之前先按这些上限拒绝。
const (
	argonMaxMemoryKiB = 512 * 1024
	argonMaxTime      = 10
	argonMaxThreads   = 16
	argonMinSaltLen   = 8
	argonMaxSaltLen   = 64
	argonMinKeyLen    = 16
	argonMaxKeyLen    = 64
)

// hashParams 是从 PHC 字符串解析并校验过的参数。
type hashParams struct {
	memory  uint32
	time    uint32
	threads uint8
	salt    []byte
	key     []byte
}

// parsePasswordHash 解析 PHC 格式并校验参数范围，任何不合法都返回 errBadHash，
// 调用方据此把它当作凭据错误，不再继续计算。
func parsePasswordHash(encoded string) (hashParams, error) {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[1] != "argon2id" {
		return hashParams{}, errBadHash
	}
	var version int
	if _, err := fmt.Sscanf(parts[2], "v=%d", &version); err != nil || version != argon2.Version {
		return hashParams{}, errBadHash
	}
	var mem, iter uint32
	var threads uint8
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &mem, &iter, &threads); err != nil {
		return hashParams{}, errBadHash
	}
	// 迭代数与并行度为 0 时 argon2 会 panic，上限则挡住故意放大的参数。
	if mem == 0 || mem > argonMaxMemoryKiB ||
		iter < 1 || iter > argonMaxTime ||
		threads < 1 || threads > argonMaxThreads {
		return hashParams{}, errBadHash
	}
	salt, err := b64.DecodeString(parts[4])
	if err != nil || len(salt) < argonMinSaltLen || len(salt) > argonMaxSaltLen {
		return hashParams{}, errBadHash
	}
	key, err := b64.DecodeString(parts[5])
	if err != nil || len(key) < argonMinKeyLen || len(key) > argonMaxKeyLen {
		return hashParams{}, errBadHash
	}
	return hashParams{memory: mem, time: iter, threads: threads, salt: salt, key: key}, nil
}

// VerifyPassword reports whether password matches the encoded hash.
func VerifyPassword(encoded, password string) (bool, error) {
	p, err := parsePasswordHash(encoded)
	if err != nil {
		return false, err
	}
	got := argon2.IDKey([]byte(password), p.salt, p.time, p.memory, p.threads, uint32(len(p.key)))
	return subtle.ConstantTimeCompare(got, p.key) == 1, nil
}

// newToken returns 32 random bytes as URL-safe base64; tokens are opaque.
func newToken() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

// hashToken is what the store keeps; the raw token only lives on the client.
func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}
