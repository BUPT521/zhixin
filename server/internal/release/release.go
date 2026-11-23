// Package release 读取应用安装包的发布清单，供应用内的更新检查使用。
//
// 清单是一份放在服务端本地的 JSON 文件，只有一个顶层字段 releases；每个平台
// 一条。服务端只校验字段是否齐全、地址是否是可用的 http(s) 地址，不比较客户端
// 版本，也不决定某次更新是否必须安装：比较规则留在客户端一处，避免两边各写一套
// 版本语义。发布清单为什么用文件而不是数据库，见 ADR-0025。
package release

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"strings"

	"github.com/BUPT521/zhixin/server/internal/httpx"
)

// Entry 是发布清单里一个平台的一条记录。
type Entry struct {
	// Platform 是平台名，例如 android。
	Platform string `json:"platform"`
	// Version 是版本名，例如 0.2.0。
	Version string `json:"version"`
	// Build 是 Android 的 versionCode。
	Build int64 `json:"build"`
	// PublishedAt 是这一版的发布日期，YYYY-MM-DD；留空表示没有写。
	PublishedAt string `json:"published_at"`
	// URL 是安装包地址，正式实例应写 https。
	URL string `json:"url"`
	// SHA256 是安装包的哈希，必填；发布清单与安装包对不上时客户端无法发现
	// 被替换的包，因此不再允许省略。
	SHA256 string `json:"sha256"`
	// Signature 是安装包 SHA-256 的 Ed25519 签名（base64），由应用使用内置公钥验证。
	Signature string `json:"signature"`
	// Size 是安装包的字节数，可选。
	Size int64 `json:"size"`
	// MinVersion 是建议客户端保持的最低版本；低于它的客户端在提示里用建议尽快
	// 更新的措辞，仍然可以关闭提示继续使用本机功能。
	MinVersion string `json:"min_version"`
	// Notes 是这一版的更新说明。
	Notes string `json:"notes"`
}

type manifest struct {
	Releases []Entry `json:"releases"`
}

// Load 读取并校验发布清单。path 为空表示还没有发布过安装包，返回空清单；
// 文件存在但内容不合法时返回错误，由启动流程直接报错。开发阶段不写迁移，
// 清单格式可以随服务端一起改（ADR-0001）。
func Load(path string) ([]Entry, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return nil, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("release: 读不到发布清单: %w", err)
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var m manifest
	if err := dec.Decode(&m); err != nil {
		return nil, fmt.Errorf("release: 发布清单不是合法的 JSON: %w", err)
	}
	// 顶层对象之后还有内容时不接受：多写一段说明性文字或第二个对象，都说明
	// 文件被改坏了。
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return nil, errors.New("release: 发布清单只能有一个 JSON 对象")
	}

	seen := make(map[string]bool, len(m.Releases))
	for i := range m.Releases {
		e := &m.Releases[i]
		e.Platform = strings.TrimSpace(e.Platform)
		e.Version = strings.TrimSpace(e.Version)
		e.PublishedAt = strings.TrimSpace(e.PublishedAt)
		e.URL = strings.TrimSpace(e.URL)
		e.SHA256 = strings.TrimSpace(e.SHA256)
		e.Signature = strings.TrimSpace(e.Signature)
		e.MinVersion = strings.TrimSpace(e.MinVersion)
		e.Notes = strings.TrimSpace(e.Notes)
		switch {
		case e.Platform == "":
			return nil, fmt.Errorf("release: 第 %d 条缺少 platform", i+1)
		case e.Version == "":
			return nil, fmt.Errorf("release: %s 缺少 version", e.Platform)
		case e.Build < 0:
			return nil, fmt.Errorf("release: %s 的 build 不能是负数", e.Platform)
		case e.Size < 0:
			return nil, fmt.Errorf("release: %s 的 size 不能是负数", e.Platform)
		}
		if seen[e.Platform] {
			return nil, fmt.Errorf("release: 平台 %s 出现了不止一条", e.Platform)
		}
		seen[e.Platform] = true
		if err := checkURL(e.URL); err != nil {
			return nil, fmt.Errorf("release: %s 的 url %w", e.Platform, err)
		}
		if !httpx.ValidSHA256(e.SHA256) {
			return nil, fmt.Errorf("release: %s 的 sha256 必填，且必须是 64 位小写十六进制", e.Platform)
		}
		sig, err := base64.StdEncoding.DecodeString(e.Signature)
		if err != nil || len(sig) != ed25519.SignatureSize {
			return nil, fmt.Errorf("release: %s 的 signature 必须是 %d 字节 Ed25519 签名的 base64", e.Platform, ed25519.SignatureSize)
		}
	}
	return m.Releases, nil
}

// checkURL 只接受 https 绝对地址：正式更新包必须走加密连接，否则清单与安装包
// 都可能在中途被替换。本机联调也走 https 或直接改清单测试，不为 http 开口子。
func checkURL(raw string) error {
	if raw == "" {
		return errors.New("不能为空")
	}
	u, err := url.Parse(raw)
	if err != nil {
		return errors.New("不是合法的地址")
	}
	if u.Scheme != "https" {
		return errors.New("必须使用 https")
	}
	if u.Host == "" {
		return errors.New("缺少主机名")
	}
	return nil
}
