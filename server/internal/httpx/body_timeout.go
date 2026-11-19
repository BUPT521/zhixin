package httpx

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

// BodyIdleTimeout 给带请求体的请求设置读取空闲期限：每次读之前刷新期限，读到
// EOF、读错、Close 或处理器返回时不再保留“无限等待”的读取。
//
// http.Server 没有设置 ReadTimeout（大文件上传与模型流式响应需要长时间连接），
// 慢速请求体因此能把连接一直占住。这里只用 ResponseController 设“读”期限，
// 不碰写期限，SSE 的响应写入不受影响。没有请求体（r.Body 为 nil 或 http.NoBody）
// 的请求直接跳过。
//
// 期限的收尾分三种情况。正常读到 EOF 或 Close 时清除期限；读超时时保留已经过期
// 的期限，让处理器之后的读和 net/http 写响应头前清理剩余请求体的那次读立刻失败，
// 不会再把连接挂住；处理器没读完就返回时给收尾读留一个期限，避免 net/http 在
// 没有期限的连接上一直等客户端把没发完的请求体发完。连接进入空闲后由 net/http
// 自己重置读期限，不影响下一个请求。
func BodyIdleTimeout(d time.Duration) func(http.Handler) http.Handler {
	if d <= 0 {
		return func(next http.Handler) http.Handler { return next }
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Body == nil || r.Body == http.NoBody {
				next.ServeHTTP(w, r)
				return
			}
			body := &idleBody{
				ReadCloser: r.Body,
				controller: http.NewResponseController(w),
				timeout:    d,
				expires:    time.Now().Add(10 * time.Minute),
			}
			r.Body = body
			defer body.finish()
			next.ServeHTTP(w, r)
		})
	}
}

// idleBody 在每次读之前把读期限推到当前时间之后 timeout，并按上面的规则收尾。
type idleBody struct {
	io.ReadCloser
	controller *http.ResponseController
	timeout    time.Duration
	expires    time.Time
	settled    bool
}

func (b *idleBody) Read(p []byte) (int, error) {
	if !b.settled {
		if err := b.controller.SetReadDeadline(b.deadline()); err != nil {
			if !errors.Is(err, http.ErrNotSupported) {
				return 0, fmt.Errorf("httpx: 设置请求体读期限失败: %w", err)
			}
			// 连接不支持设置读期限（HTTP/2 的某些实现、测试里的内存
			// ResponseWriter）：不设期限继续读，不能因此让正常请求失败。
			b.settled = true
		}
	}
	n, err := b.ReadCloser.Read(p)
	switch {
	case err == nil:
		// 还有数据，下一次读之前会把期限再往后推。
	case errors.Is(err, io.EOF):
		b.clear()
	case os.IsTimeout(err):
		// 读超时说明对端不再发送；保留已经过期的期限，处理器往后的读与
		// net/http 写响应头前清理剩余请求体的那次读都会立即失败。
		b.settled = true
	default:
		// 其他读错说明连接已经坏了，后续读不会再阻塞。
		b.clear()
	}
	return n, err
}

func (b *idleBody) Close() error {
	b.clear()
	return b.ReadCloser.Close()
}

// clear 清除读期限；重复调用无害。
func (b *idleBody) clear() {
	if b.settled {
		return
	}
	b.settled = true
	_ = b.controller.SetReadDeadline(time.Time{})
}

// finish 在处理器返回时收尾：读完、关闭或读超时的请求体已经处理过；还没读完的
// 给 net/http 写响应头前清理剩余请求体的那次读留一个期限。
func (b *idleBody) finish() {
	if b.settled {
		return
	}
	b.settled = true
	_ = b.controller.SetReadDeadline(b.deadline())
}

func (b *idleBody) deadline() time.Time {
	idle := time.Now().Add(b.timeout)
	if b.expires.Before(idle) {
		return b.expires
	}
	return idle
}
