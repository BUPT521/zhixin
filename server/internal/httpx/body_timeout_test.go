package httpx

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

// deadlineRecorder 记下中间件通过 http.ResponseController 设置的读期限，用的是
// httptest.ResponseRecorder 本身做不到的那部分接口。
type deadlineRecorder struct {
	httptest.ResponseRecorder
	mu        sync.Mutex
	deadlines []time.Time
}

func (d *deadlineRecorder) SetReadDeadline(deadline time.Time) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.deadlines = append(d.deadlines, deadline)
	return nil
}

func (d *deadlineRecorder) recorded() []time.Time {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]time.Time(nil), d.deadlines...)
}

// unwrapWriter 包一层，核对 ResponseController 能顺着 Unwrap 找到底层 writer。
type unwrapWriter struct{ http.ResponseWriter }

func (u unwrapWriter) Unwrap() http.ResponseWriter { return u.ResponseWriter }

func TestBodyIdleTimeoutSetsAndClearsDeadline(t *testing.T) {
	rec := &deadlineRecorder{ResponseRecorder: *httptest.NewRecorder()}
	body := io.NopCloser(io.LimitReader(neverEnding('x'), 5))
	handler := BodyIdleTimeout(time.Minute)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, err := io.ReadAll(r.Body); err != nil {
			t.Errorf("读请求体：%v", err)
		}
	}))
	handler.ServeHTTP(unwrapWriter{ResponseWriter: rec}, httptest.NewRequest(http.MethodPost, "/", body))

	deadlines := rec.recorded()
	if len(deadlines) == 0 {
		t.Fatal("中间件没有设置读期限")
	}
	if deadlines[0].IsZero() {
		t.Fatal("第一次读之前应当设置一个未来的期限")
	}
	if !deadlines[0].After(time.Now()) {
		t.Fatalf("读期限应当在未来，得到 %v", deadlines[0])
	}
	if last := deadlines[len(deadlines)-1]; !last.IsZero() {
		t.Fatalf("读到 EOF 之后应当清除期限，最后一次设置 %v", last)
	}
}

// TestBodyIdleTimeoutArmsDrainGuardWhenBodyUnread 核对处理器没读请求体就返回时
// （鉴权失败、参数绑定失败就是这样）不会留下无限等待的收尾读：中间件给
// net/http 清理剩余请求体的那次读留一个期限。
func TestBodyIdleTimeoutArmsDrainGuardWhenBodyUnread(t *testing.T) {
	rec := &deadlineRecorder{ResponseRecorder: *httptest.NewRecorder()}
	handler := BodyIdleTimeout(time.Minute)(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		// 处理器不读请求体。
	}))
	body := io.NopCloser(io.LimitReader(neverEnding('x'), 5))
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/", body))

	deadlines := rec.recorded()
	if len(deadlines) != 1 || deadlines[0].IsZero() || !deadlines[0].After(time.Now()) {
		t.Fatalf("处理器返回时应当给收尾读留一个未来的期限，得到 %v", deadlines)
	}
}

// TestBodyIdleTimeoutDoesNotRearmAfterTimeout 核对该超时之后不再刷新期限：保留
// 已经过期的期限，让后续读（包括 net/http 的收尾读）立即失败。
func TestBodyIdleTimeoutDoesNotRearmAfterTimeout(t *testing.T) {
	rec := &deadlineRecorder{ResponseRecorder: *httptest.NewRecorder()}
	handler := BodyIdleTimeout(time.Minute)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, err := r.Body.Read(make([]byte, 4)); err == nil {
			t.Error("应当返回请求体读错误")
		}
		if _, err := r.Body.Read(make([]byte, 4)); err == nil {
			t.Error("第二次读也应当返回错误")
		}
	}))
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/", timeoutBody{}))

	// 只应有第一次读之前的一次设置；超时之后既不清除（保留过期期限）也不再刷新。
	if deadlines := rec.recorded(); len(deadlines) != 1 || deadlines[0].IsZero() {
		t.Fatalf("超时之后应当保留期限且不再刷新，得到 %v", deadlines)
	}
}

func TestBodyIdleTimeoutSkipsRequestsWithoutBody(t *testing.T) {
	for _, body := range []io.ReadCloser{nil, http.NoBody} {
		rec := &deadlineRecorder{}
		handler := BodyIdleTimeout(time.Minute)(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
		req := httptest.NewRequest(http.MethodGet, "/", nil)
		req.Body = body
		handler.ServeHTTP(rec, req)
		if deadlines := rec.recorded(); len(deadlines) != 0 {
			t.Fatalf("没有请求体时不该设置期限，得到 %v", deadlines)
		}
	}
}

// TestBodyIdleTimeoutLeavesResponseWritesAlone 核对读完请求体之后清除期限，
// 后续写响应与刷新（模型流式响应走这条路径）不受影响。
func TestBodyIdleTimeoutLeavesResponseWritesAlone(t *testing.T) {
	rec := &deadlineRecorder{ResponseRecorder: *httptest.NewRecorder()}
	handler := BodyIdleTimeout(50 * time.Millisecond)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, err := io.Copy(io.Discard, r.Body); err != nil {
			t.Errorf("读请求体：%v", err)
		}
		flusher, ok := w.(http.Flusher)
		if !ok {
			t.Error("处理器拿不到 http.Flusher")
			return
		}
		_, _ = w.Write([]byte("data: one\n\n"))
		flusher.Flush()
	}))
	body := io.NopCloser(io.LimitReader(neverEnding('x'), 3))
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/", body))

	if rec.Code != http.StatusOK || !rec.Flushed {
		t.Fatalf("写响应与刷新应当正常：status=%d flushed=%v", rec.Code, rec.Flushed)
	}
	if got := rec.Body.String(); got != "data: one\n\n" {
		t.Fatalf("响应体 = %q", got)
	}
}

// TestBodyIdleTimeoutStopsSlowBody 用真实连接发一个只写了半个请求体的请求：
// 读期限到期后读取返回错误，处理器据此回 408，而不是一直占着连接。
func TestBodyIdleTimeoutStopsSlowBody(t *testing.T) {
	handler := BodyIdleTimeout(150 * time.Millisecond)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, err := io.Copy(io.Discard, r.Body); err != nil {
			w.WriteHeader(http.StatusRequestTimeout)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	srv := httptest.NewServer(handler)
	defer srv.Close()

	conn, err := net.Dial("tcp", srv.Listener.Addr().String())
	if err != nil {
		t.Fatalf("连接测试服务器：%v", err)
	}
	defer conn.Close()
	// Content-Length 是 10，只发 3 个字节，剩下的永远不发。
	if _, err := fmt.Fprintf(conn, "POST /slow HTTP/1.1\r\nHost: test\r\nContent-Length: 10\r\n\r\nabc"); err != nil {
		t.Fatalf("写请求：%v", err)
	}
	if err := conn.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatalf("设置客户端读期限：%v", err)
	}
	resp, err := http.ReadResponse(bufio.NewReader(conn), &http.Request{Method: http.MethodPost})
	if err != nil {
		t.Fatalf("读响应：%v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusRequestTimeout {
		t.Fatalf("慢请求体应当因读期限到期返回 408，得到 %d", resp.StatusCode)
	}
}

// neverEnding 造一个一直有数据可读的读取器；Read 永不阻塞，也不会提前返回 EOF。
type neverEnding byte

func (b neverEnding) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = byte(b)
	}
	return len(p), nil
}

// timeoutBody 每次读都返回读期限到期的错误，模拟慢请求体被读期限打断。
type timeoutBody struct{}

func (timeoutBody) Read([]byte) (int, error) { return 0, context.DeadlineExceeded }

func (timeoutBody) Close() error { return nil }
