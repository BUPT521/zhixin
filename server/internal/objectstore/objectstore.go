// Package objectstore 保存字节对象：整库备份与附件。
//
// 键是 bucket 内的相对路径，整库备份是 backups/<账号>/<id>.zip，附件是
// attachments/<账号>/<sha256>；S3 兼容存储、本地目录与内存三种实现共用这套键
// （ADR-0016）。三种实现都在核对大小之后才把对象放到最终位置，读取方不会看到
// 写了一半的备份或附件。
package objectstore

import (
	"context"
	"errors"
	"io"
	"time"
)

// Info 描述一个对象的大小与内容类型。写入时 Size 必须等于 data 的字节数。
type Info struct {
	Size        int64
	ContentType string
}

// Object 是前缀下列出的一个对象：键与写入时间。列目录只服务于备份对账（按
// 前缀找出没有元数据的遗留对象）与排查遗留字节，不返回大小、内容类型这类只有
// 写入方关心的字段；ModTime 由备份对账用来判断对象是否超过宽限期，见 ADR-0037。
type Object struct {
	Key     string
	ModTime time.Time
}

// ErrNotFound 表示键下没有对象。
var ErrNotFound = errors.New("objectstore: 对象不存在")

// 对象键的公共前缀只在这里定义：备份与附件的键、删除账号时的账号前缀，以及
// 后台对账扫描的前缀都从这两个常量拼出来，键规则因此只有一处（ADR-0037）。
const (
	// BackupObjectPrefix 是全部整库备份对象共用的键前缀。
	BackupObjectPrefix = "backups/"
	// AttachmentObjectPrefix 是全部附件对象共用的键前缀。
	AttachmentObjectPrefix = "attachments/"
)

// BackupKey 是整库备份在对象存储里的键：backups/<账号>/<id>.zip。
func BackupKey(userID, id string) string {
	return BackupPrefix(userID) + id + ".zip"
}

// BackupPrefix 是一个账号全部备份的前缀，删除账号时按它清理。
func BackupPrefix(userID string) string { return BackupObjectPrefix + userID + "/" }

// AttachmentKey 是附件在对象存储里的键：attachments/<账号>/<sha256>。
func AttachmentKey(userID, sha string) string {
	return AttachmentPrefix(userID) + sha
}

// AttachmentPrefix 是一个账号全部附件的前缀。
func AttachmentPrefix(userID string) string {
	return AttachmentObjectPrefix + userID + "/"
}

// Store 是三种实现共用的接口。
type Store interface {
	// Put 写入一个对象，Info.Size 必须等于 data 的字节数。
	Put(ctx context.Context, key string, data io.Reader, info Info) error
	// Open 返回对象内容与元数据；不存在时返回 ErrNotFound。
	Open(ctx context.Context, key string) (io.ReadCloser, Info, error)
	// Stat 只取元数据；不存在时返回 ErrNotFound。
	Stat(ctx context.Context, key string) (Info, error)
	// Remove 删除一个对象；不存在时不算错误。
	Remove(ctx context.Context, key string) error
	// RemovePrefix 删除以 prefix 开头的全部对象，删除账号时用。
	RemovePrefix(ctx context.Context, prefix string) error
	// List 返回以 prefix 开头的全部对象；没有对象时返回空切片而不是错误。
	// 备份对账要按前缀列出对象，所以三种实现都要能列目录。
	List(ctx context.Context, prefix string) ([]Object, error)
	// Ping 报告存储是否可用，供 /readyz 使用。
	Ping(ctx context.Context) error
}
