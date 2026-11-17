// Package release 读取应用安装包的发布清单，供应用内的更新检查使用。
//
// 清单是一份放在服务端本地的 JSON 文件，只有一个顶层字段 releases；每个平台
// 一条。服务端只校验字段是否齐全、地址是否是可用的 http(s) 地址，不比较客户端
// 版本，也不决定某次更新是否必须安装：比较规则留在客户端一处，避免两边各写一套
// 版本语义。发布清单为什么用文件而不是数据库，见 ADR-0025。
package release

import (
	"bytes"
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
	// SHA256 是安装包的哈希，可选；写了就校验格式。
	SHA256 string `json:"sha256"`
	// Size 是安装包的字节数，可选。
	Size int64 `json:"size"`
	// MinVersion 是仍然可以使用的版本下限；低于它的客户端应提示必须更新。
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
		if e.SHA256 != "" && !httpx.ValidSHA256(e.SHA256) {
			return nil, fmt.Errorf("release: %s 的 sha256 必须是 64 位小写十六进制", e.Platform)
		}
	}
	return m.Releases, nil
}

// checkURL 只接受绝对地址，协议限 http 与 https。正式实例应写 https，本地
// 联调允许 http；这里不替部署环境做这个选择。
func checkURL(raw string) error {
	if raw == "" {
		return errors.New("不能为空")
	}
	u, err := url.Parse(raw)
	if err != nil {
		return errors.New("不是合法的地址")
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return errors.New("只能用 http 或 https")
	}
	if u.Host == "" {
		return errors.New("缺少主机名")
	}
	return nil
}
