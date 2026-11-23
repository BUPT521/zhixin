package server

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"testing"
)

// TestClientSchemaVersionMatchesDocs 守住服务端接受的客户端版本与 01 开头的
// 数据结构版本一致。docs/01 是数据结构的唯一真相，客户端常量与
// ClientSchemaVersion 各自跟着它走；两边任何一侧漏改，同步与备份都会在线上
// 才暴露，所以这里在 CI 里直接比对。
func TestClientSchemaVersionMatchesDocs(t *testing.T) {
	path := filepath.Join("..", "..", "..", "docs", "01-ER数据模型.md")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取 %s：%v", path, err)
	}
	match := regexp.MustCompile(`当前结构为 schema (\d+)`).FindSubmatch(raw)
	if match == nil {
		t.Fatal("01 开头没有写“当前结构为 schema N”")
	}
	documented, err := strconv.Atoi(string(match[1]))
	if err != nil {
		t.Fatalf("解析 01 的版本号：%v", err)
	}
	if documented != ClientSchemaVersion {
		t.Fatalf("01 是 schema %d，ClientSchemaVersion 是 %d，两边要一起改", documented, ClientSchemaVersion)
	}
}
