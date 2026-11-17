package release

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const manifestBody = `{
  "releases": [
    {
      "platform": "android",
      "version": "0.2.0",
      "build": 2,
      "published_at": "2026-12-21",
      "url": "https://example.test/zhixin-0.2.0.apk",
      "sha256": "` + zeroSHA + `",
      "size": 48200000,
      "min_version": "0.1.0",
      "notes": "登录、云端备份与同步"
    }
  ]
}`

const zeroSHA = "0000000000000000000000000000000000000000000000000000000000000000"

func writeManifest(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "releases.json")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	return path
}

func TestLoadReadsManifest(t *testing.T) {
	entries, err := Load(writeManifest(t, manifestBody))
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("应读到 1 条，得到 %d", len(entries))
	}
	got := entries[0]
	if got.Platform != "android" || got.Version != "0.2.0" || got.Build != 2 {
		t.Fatalf("基本字段不对：%+v", got)
	}
	if got.PublishedAt != "2026-12-21" || got.URL != "https://example.test/zhixin-0.2.0.apk" {
		t.Fatalf("发布日期或地址不对：%+v", got)
	}
	if got.SHA256 != zeroSHA || got.Size != 48200000 || got.MinVersion != "0.1.0" {
		t.Fatalf("可选字段不对：%+v", got)
	}
	if got.Notes != "登录、云端备份与同步" {
		t.Fatalf("更新说明不对：%q", got.Notes)
	}
}

func TestLoadTrimsAndAllowsEmptyList(t *testing.T) {
	path := writeManifest(t, `{"releases":[{"platform":" android ","version":" 0.2.0 ","build":1,"url":"https://example.test/a.apk"}]}`)
	entries, err := Load(path)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if entries[0].Platform != "android" || entries[0].Version != "0.2.0" {
		t.Fatalf("两端空白应去掉：%+v", entries[0])
	}

	empty, err := Load(writeManifest(t, `{"releases":[]}`))
	if err != nil {
		t.Fatalf("空清单应被接受：%v", err)
	}
	if len(empty) != 0 {
		t.Fatalf("空清单应返回 0 条，得到 %d", len(empty))
	}
}

func TestLoadWithoutFile(t *testing.T) {
	entries, err := Load("   ")
	if err != nil {
		t.Fatalf("空路径表示还没有配置，不应报错：%v", err)
	}
	if entries != nil {
		t.Fatalf("空路径应返回 nil，得到 %+v", entries)
	}
	if _, err := Load(filepath.Join(t.TempDir(), "missing.json")); err == nil {
		t.Fatal("文件不存在时应报错")
	}
}

func TestLoadRejectsBadManifest(t *testing.T) {
	cases := []struct {
		name string
		body string
	}{
		{"不是 JSON", "releases: android"},
		{"顶层多一段内容", `{"releases":[]} {}`},
		{"未知字段", `{"releases":[],"channel":"beta"}`},
		{"缺 platform", `{"releases":[{"version":"0.2.0","build":1,"url":"https://example.test/a.apk"}]}`},
		{"缺 version", `{"releases":[{"platform":"android","build":1,"url":"https://example.test/a.apk"}]}`},
		{"负数 build", `{"releases":[{"platform":"android","version":"0.2.0","build":-1,"url":"https://example.test/a.apk"}]}`},
		{"负数 size", `{"releases":[{"platform":"android","version":"0.2.0","build":1,"url":"https://example.test/a.apk","size":-1}]}`},
		{"地址为空", `{"releases":[{"platform":"android","version":"0.2.0","build":1,"url":""}]}`},
		{"地址没有主机", `{"releases":[{"platform":"android","version":"0.2.0","build":1,"url":"https:///a.apk"}]}`},
		{"地址协议不对", `{"releases":[{"platform":"android","version":"0.2.0","build":1,"url":"ftp://example.test/a.apk"}]}`},
		{"哈希格式不对", `{"releases":[{"platform":"android","version":"0.2.0","build":1,"url":"https://example.test/a.apk","sha256":"abc"}]}`},
		{"平台重复", `{"releases":[
			{"platform":"android","version":"0.1.0","build":1,"url":"https://example.test/a.apk"},
			{"platform":"android","version":"0.2.0","build":2,"url":"https://example.test/b.apk"}
		]}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := Load(writeManifest(t, tc.body)); err == nil {
				t.Fatal("不合法的清单应当报错")
			}
		})
	}
}

func TestLoadErrorMessageNamesThePlatform(t *testing.T) {
	_, err := Load(writeManifest(t, `{"releases":[{"platform":"android","version":"0.2.0","build":1,"url":"ftp://x/a.apk"}]}`))
	if err == nil {
		t.Fatal("应当报错")
	}
	if !strings.Contains(err.Error(), "android") {
		t.Fatalf("错误信息应指出是哪一条：%v", err)
	}
}
