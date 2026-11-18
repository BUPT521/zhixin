package objectstore

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// Dir 把对象写到本地目录，用于没有配置对象存储的开发环境。键里的斜杠就是
// 目录层级，部署时给它一个不在代码目录里的路径。
type Dir struct {
	root string
}

// NewDir 准备根目录；root 为空时返回错误，避免字节悄悄写进当前目录。
func NewDir(root string) (*Dir, error) {
	if strings.TrimSpace(root) == "" {
		return nil, errors.New("objectstore: 本地目录为空")
	}
	if err := os.MkdirAll(root, 0o750); err != nil {
		return nil, fmt.Errorf("objectstore: 建本地目录失败: %w", err)
	}
	return &Dir{root: root}, nil
}

// path 把键映射到根目录下的文件。键必须是目录内的相对路径，带 .. 的键
// 一律拒绝，免得一次改名写到目录之外。
func (d *Dir) path(key string) (string, error) {
	rel := filepath.FromSlash(key)
	if key == "" || !filepath.IsLocal(rel) {
		return "", fmt.Errorf("objectstore: 键 %q 不是目录内的相对路径", key)
	}
	return filepath.Join(d.root, rel), nil
}

func (d *Dir) Put(_ context.Context, key string, data io.Reader, info Info) error {
	path, err := d.path(key)
	if err != nil {
		return err
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".part-*")
	if err != nil {
		return err
	}
	defer func() {
		_ = tmp.Close()
		_ = os.Remove(tmp.Name())
	}()
	n, err := io.Copy(tmp, data)
	if err != nil {
		return err
	}
	if n != info.Size {
		return fmt.Errorf("objectstore: 实际写入 %d 字节，与声明的 %d 不符", n, info.Size)
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	// 先写临时文件再改名：读取方不会看到写了一半的对象。
	return os.Rename(tmp.Name(), path)
}

func (d *Dir) Open(_ context.Context, key string) (io.ReadCloser, Info, error) {
	path, err := d.path(key)
	if err != nil {
		return nil, Info{}, err
	}
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, Info{}, ErrNotFound
	}
	if err != nil {
		return nil, Info{}, err
	}
	st, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return nil, Info{}, err
	}
	return f, Info{Size: st.Size()}, nil
}

func (d *Dir) Stat(_ context.Context, key string) (Info, error) {
	path, err := d.path(key)
	if err != nil {
		return Info{}, err
	}
	st, err := os.Stat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return Info{}, ErrNotFound
	}
	if err != nil {
		return Info{}, err
	}
	return Info{Size: st.Size()}, nil
}

func (d *Dir) Remove(_ context.Context, key string) error {
	path, err := d.path(key)
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

func (d *Dir) RemovePrefix(_ context.Context, prefix string) error {
	if prefix == "" {
		return errors.New("objectstore: 拒绝删除空前缀")
	}
	path, err := d.path(strings.TrimSuffix(prefix, "/"))
	if err != nil {
		return err
	}
	if err := os.RemoveAll(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	// 账号目录删掉之后，上一级目录可能空了；空目录留着无碍，不在这里递归清理。
	return nil
}

// List 按前缀列出对象。前缀按斜杠分段，最后一段可能只是键的开头，所以走前缀
// 所在的目录、再按完整前缀过滤；前缀目录不存在时返回空切片，不算错误。
func (d *Dir) List(_ context.Context, prefix string) ([]Object, error) {
	if prefix == "" {
		return nil, errors.New("objectstore: 拒绝列出空前缀")
	}
	dirKey := strings.TrimSuffix(prefix, "/")
	if i := strings.LastIndex(dirKey, "/"); i >= 0 {
		dirKey = dirKey[:i]
	} else {
		dirKey = ""
	}
	root := d.root
	if dirKey != "" {
		rel := filepath.FromSlash(dirKey)
		if !filepath.IsLocal(rel) {
			return nil, fmt.Errorf("objectstore: 前缀 %q 不在根目录内", dirKey)
		}
		root = filepath.Join(d.root, rel)
	}
	out := make([]Object, 0)
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(d.root, path)
		if err != nil {
			return err
		}
		key := filepath.ToSlash(rel)
		if !strings.HasPrefix(key, prefix) {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		out = append(out, Object{Key: key, Size: info.Size()})
		return nil
	})
	if errors.Is(err, fs.ErrNotExist) {
		return out, nil
	}
	return out, err
}

func (d *Dir) Ping(_ context.Context) error {
	st, err := os.Stat(d.root)
	if err != nil {
		return fmt.Errorf("objectstore: 本地目录不可用: %w", err)
	}
	if !st.IsDir() {
		return fmt.Errorf("objectstore: %s 不是目录", d.root)
	}
	return nil
}
