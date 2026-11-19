// Package secretbox 加密保存在数据库里的少量机密，目前只有模型来源的 key。
//
// 算法是 AES-256-GCM，密钥来自 ZHIXIN_SECRET_KEY（32 字节的 base64）。密文的
// 格式是 "v1:" 加 base64(nonce || ciphertext)，前缀留给以后换算法或换密钥。
// 数据库与它的备份泄露时，没有这把密钥就读不出 key；密钥本身只在服务器的环境
// 变量里，不进仓库、不进数据库。
package secretbox

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
)

const prefix = "v1:"

// ErrUndecryptable 表示密文损坏或者不是用当前密钥加密的。
var ErrUndecryptable = errors.New("secretbox: cannot decrypt with the current key")

// Box 用一把固定密钥加解密。零值不可用，用 New 或 Random 创建。
type Box struct {
	aead cipher.AEAD
}

// ParseKey 解析 ZHIXIN_SECRET_KEY：标准或 URL 安全的 base64，带不带填充都可以，
// 解出来必须正好 32 字节。
func ParseKey(s string) ([]byte, error) {
	s = strings.TrimSpace(s)
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		if key, err := enc.DecodeString(s); err == nil {
			if len(key) != 32 {
				return nil, fmt.Errorf("want 32 bytes after base64 decoding, got %d", len(key))
			}
			return key, nil
		}
	}
	return nil, errors.New("not valid base64; generate one with `openssl rand -base64 32`")
}

// New 用 32 字节密钥创建 Box。
func New(key []byte) (*Box, error) {
	if len(key) != 32 {
		return nil, fmt.Errorf("secretbox: want a 32-byte key, got %d", len(key))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &Box{aead: aead}, nil
}

// Random 生成一把只在本进程有效的密钥，供内存存储使用：数据随进程消失，密钥
// 也不需要保留。
func Random() *Box {
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		panic(err) // crypto/rand 失败时进程本来也无法继续
	}
	b, _ := New(key)
	return b
}

// Seal 加密 plaintext；空字符串原样返回空字符串，表示“没有设置”。aad 是不加密
// 但参与认证的附加数据：解密时必须给出相同的 aad，密文因此不能被挪到别的
// 记录上使用（例如把一把 key 挪给另一个地址）。
func (b *Box) Seal(plaintext, aad string) (string, error) {
	if plaintext == "" {
		return "", nil
	}
	nonce := make([]byte, b.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	out := b.aead.Seal(nonce, nonce, []byte(plaintext), []byte(aad))
	return prefix + base64.StdEncoding.EncodeToString(out), nil
}

// Open 解密 Seal 的结果；空字符串返回空字符串。aad 必须与加密时相同。
func (b *Box) Open(sealed, aad string) (string, error) {
	if sealed == "" {
		return "", nil
	}
	body, ok := strings.CutPrefix(sealed, prefix)
	if !ok {
		return "", ErrUndecryptable
	}
	raw, err := base64.StdEncoding.DecodeString(body)
	if err != nil || len(raw) < b.aead.NonceSize() {
		return "", ErrUndecryptable
	}
	n := b.aead.NonceSize()
	plain, err := b.aead.Open(nil, raw[:n], raw[n:], []byte(aad))
	if err != nil {
		return "", ErrUndecryptable
	}
	return string(plain), nil
}
