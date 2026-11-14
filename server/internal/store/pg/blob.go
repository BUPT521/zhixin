package pg

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// BlobStore 保存备份的字节。对象存储就绪前用本地目录顶上，
// 这样进程重启之后备份仍然在；换成 S3 时只替换这一个实现。
type BlobStore interface {
	Put(ctx context.Context, userID, id string, data io.Reader) (int64, error)
	Open(ctx context.Context, userID, id string) (io.ReadCloser, error)
	Remove(ctx context.Context, userID, id string) error
}

// FilesystemBlobs 把字节写到 <dir>/<userID>/<id>.zip。
type FilesystemBlobs struct {
	dir string
}

// NewFilesystemBlobs 准备目录；dir 为空时返回只报错的实现，避免静默丢数据。
func NewFilesystemBlobs(dir string) (BlobStore, error) {
	if dir == "" {
		return nil, errors.New("pg: 备份字节需要 ZHIXIN_BLOB_DIR，用它指定落盘目录；对象存储就绪后可以不再配置")
	}
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, fmt.Errorf("pg: 建备份目录失败: %w", err)
	}
	return &FilesystemBlobs{dir: dir}, nil
}

func (f *FilesystemBlobs) path(userID, id string) string {
	return filepath.Join(f.dir, userID, id+".zip")
}

func (f *FilesystemBlobs) Put(_ context.Context, userID, id string, data io.Reader) (int64, error) {
	dir := filepath.Join(f.dir, userID)
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return 0, err
	}
	tmp, err := os.CreateTemp(dir, id+".*.part")
	if err != nil {
		return 0, err
	}
	defer func() {
		_ = tmp.Close()
		_ = os.Remove(tmp.Name())
	}()
	n, err := io.Copy(tmp, data)
	if err != nil {
		return 0, err
	}
	if err := tmp.Close(); err != nil {
		return 0, err
	}
	// 先写临时文件再改名：读取方不会看到写了一半的备份。
	if err := os.Rename(tmp.Name(), f.path(userID, id)); err != nil {
		return 0, err
	}
	return n, nil
}

func (f *FilesystemBlobs) Open(_ context.Context, userID, id string) (io.ReadCloser, error) {
	return os.Open(f.path(userID, id))
}

func (f *FilesystemBlobs) Remove(_ context.Context, userID, id string) error {
	err := os.Remove(f.path(userID, id))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}
