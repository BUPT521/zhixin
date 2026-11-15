package httpx

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"regexp"
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

// sha256Pattern 与 openapi.yaml 里路径参数和头参数的 pattern 一致。
var sha256Pattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

// ValidSHA256 报告 s 是不是 64 位小写十六进制，与契约里的 pattern 相同。
// 附件路径与服务端核对备份的 X-Content-SHA256 都从这里判断，不各写一份正则。
func ValidSHA256(s string) bool { return sha256Pattern.MatchString(s) }

// SpoolCheck 描述一次请求体落盘的约定：上限、期望的哈希与两条错误文案。
type SpoolCheck struct {
	// Limit 是字节上限，0 表示不设上限。
	Limit int64
	// SHA256 是期望的内容哈希，必须与请求体算出的结果一致。
	SHA256 string
	// TooLarge 是超过上限时 413 的 detail。
	TooLarge string
	// Mismatch 是哈希不一致时 400 的 detail。
	Mismatch string
}

// SpoolVerified 把请求体落进临时文件，核对大小与哈希，并把失败写成 problem
// 响应：超限 413 payload_too_large、哈希不符 400 invalid_request、读不出来
// 400 invalid_request，其余错误 500。
//
// 备份与附件原来各写一遍 ContentLength 预检、ErrBodyTooLarge 与 ErrBodyRead
// 分支、哈希比对与文案；收在这里之后，两个处理器只声明自己的约定。
func SpoolVerified(w http.ResponseWriter, r *http.Request, log *slog.Logger, check SpoolCheck) (*Spool, bool) {
	spool, err := SpoolBody(w, r, check.Limit)
	if err != nil {
		switch {
		case errors.Is(err, ErrBodyTooLarge):
			WriteProblem(w, r, http.StatusRequestEntityTooLarge, CodePayloadTooLarge, check.TooLarge)
		case errors.Is(err, ErrBodyRead):
			WriteProblem(w, r, http.StatusBadRequest, CodeInvalidRequest, "could not read body")
		default:
			WriteInternal(w, r, log, err)
		}
		return nil, false
	}
	if spool.SHA256 != check.SHA256 {
		_ = spool.Close()
		WriteProblem(w, r, http.StatusBadRequest, CodeInvalidRequest, check.Mismatch)
		return nil, false
	}
	return spool, true
}

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
