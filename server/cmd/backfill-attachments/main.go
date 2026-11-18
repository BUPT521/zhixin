// Command backfill-attachments 从对象存储回填附件索引。
//
// 附件索引（attachment 表）是账号总量配额的依据。早期版本只把字节写进对象
// 存储，升级之后这些附件的索引是空的，配额会少算；本命令遍历 attachments/
// 前缀，按对象键解出账号与 sha256 后幂等写入索引，可以重复执行。配置与服务端
// 相同，用 ZHIXIN_* 环境变量（ZHIXIN_DATABASE_URL、ZHIXIN_BLOB_DIR 或
// ZHIXIN_S3_*），建议在停写窗口内运行。
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/BUPT521/zhixin/server/internal/config"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/objectstore"
	"github.com/BUPT521/zhixin/server/internal/store/pg"
)

func main() {
	if err := run(context.Background()); err != nil {
		fmt.Fprintf(os.Stderr, "backfill-attachments: %v\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context) error {
	cfg, err := config.Load(os.Getenv)
	if err != nil {
		return err
	}
	if cfg.DatabaseURL == "" {
		return errors.New("需要 ZHIXIN_DATABASE_URL：附件索引保存在 PostgreSQL 里")
	}
	objects, err := openObjects(cfg)
	if err != nil {
		return err
	}
	store, err := pg.Open(ctx, cfg.DatabaseURL, pg.Options{Objects: objects})
	if err != nil {
		return err
	}
	defer store.Close()

	items, err := objects.List(ctx, "attachments/")
	if err != nil {
		return fmt.Errorf("列出附件对象失败: %w", err)
	}
	blobs := pg.NewBlobStore(store)
	var inserted, existing, skipped, failed int
	for _, item := range items {
		userID, sha, ok := parseAttachmentKey(item.Key)
		if !ok {
			// 目录实现写字节时的 .part- 临时文件也会被列出来；形状不对的对象
			// 不属于附件，跳过并计入统计，不让一个残留文件中断整次回填。
			skipped++
			continue
		}
		added, err := blobs.BackfillAttachment(ctx, userID, sha, item.Size)
		if err != nil {
			// 账号已删时外键会拒绝写入；这类对象由账号清理负责，不计入失败，
			// 但要打印出来供核对。
			fmt.Fprintf(os.Stderr, "跳过 %s: %v\n", item.Key, err)
			failed++
			continue
		}
		if added {
			inserted++
		} else {
			existing++
		}
	}
	fmt.Printf(
		"扫描附件对象 %d 个：新增索引 %d，已存在 %d，跳过 %d，失败 %d\n",
		len(items), inserted, existing, skipped, failed,
	)
	if failed > 0 {
		return fmt.Errorf("%d 个对象回填失败，处理完账号问题后可重复执行", failed)
	}
	return nil
}

// parseAttachmentKey 把附件键拆成账号与 sha256。键的格式是
// attachments/<账号>/<sha256>，任何多余层级或形状不对的哈希都不认，避免把
// 临时文件、目录残留或别的对象误写进索引。
func parseAttachmentKey(key string) (userID, sha string, ok bool) {
	rest, found := strings.CutPrefix(key, "attachments/")
	if !found {
		return "", "", false
	}
	userID, sha, found = strings.Cut(rest, "/")
	if !found || userID == "" || strings.Contains(sha, "/") || !httpx.ValidSHA256(sha) {
		return "", "", false
	}
	return userID, sha, true
}

// openObjects 选择字节的存放位置，规则与服务端一致：配置了 S3 兼容存储就用它，
// 否则用 ZHIXIN_BLOB_DIR。
func openObjects(cfg config.Config) (objectstore.Store, error) {
	if cfg.S3.Configured() {
		return objectstore.NewS3(cfg.S3)
	}
	return objectstore.NewDir(cfg.BlobDir)
}
