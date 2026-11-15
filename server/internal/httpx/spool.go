package httpx

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
)

// Spool 是落到临时文件的请求体：大小与 SHA-256 在读取时顺手算出，之后再交给
// 存储写入。备份与附件都有几十兆，放在内存里会随并发上涨，所以统一走这里。
type Spool struct {
	file   *os.File
	Size   int64
	SHA256 string
}

var (
	// ErrBodyTooLarge 报告请求体超过上限，调用方应返回 413。
	ErrBodyTooLarge = errors.New("httpx: 请求体超过上限")
	// ErrBodyRead 报告读请求体失败（连接中断等），调用方应返回 400。
	ErrBodyRead = errors.New("httpx: 读取请求体失败")
)

// SpoolBody 把请求体读进临时文件并计算 SHA-256；limit 为 0 表示不设上限。
// 调用方必须 Close，Close 会关掉并删掉临时文件。
func SpoolBody(w http.ResponseWriter, r *http.Request, limit int64) (*Spool, error) {
	if limit > 0 && r.ContentLength > limit {
		return nil, ErrBodyTooLarge
	}
	file, err := os.CreateTemp("", "zhixin-body-*")
	if err != nil {
		return nil, err
	}
	var body io.Reader = r.Body
	if limit > 0 {
		body = http.MaxBytesReader(w, r.Body, limit)
	}
	hash := sha256.New()
	n, err := io.Copy(io.MultiWriter(file, hash), body)
	if err != nil {
		_ = file.Close()
		_ = os.Remove(file.Name())
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			return nil, ErrBodyTooLarge
		}
		return nil, fmt.Errorf("%w: %v", ErrBodyRead, err)
	}
	return &Spool{file: file, Size: n, SHA256: hex.EncodeToString(hash.Sum(nil))}, nil
}

// Reader 把读位置移回开头，返回可以交给存储写入的读取器。
func (s *Spool) Reader() (io.Reader, error) {
	if _, err := s.file.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	return s.file, nil
}

// Close 关掉临时文件并删掉它；重复调用无害。
func (s *Spool) Close() error {
	if s.file == nil {
		return nil
	}
	name := s.file.Name()
	err := s.file.Close()
	_ = os.Remove(name)
	s.file = nil
	return err
}
