package llmproxy

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"time"
)

// maxPreludeBytes 是首个有效输出之前最多暂存的字节数。开场事件（response.created、
// response.in_progress 与心跳）只有几十个字节，64 KiB 足够覆盖常见的开场；超过时
// 不再等首字，直接把已经读到的内容交给客户端，不再占更多实例内存。
const maxPreludeBytes = 64 << 10

// prelude 是流式响应在首个有效输出之前读到的事件与读到的结果。
type prelude struct {
	// buf 是已经读到的原始字节，确认可以交付之后原样转发。
	buf []byte
	// ready 表示已经读到可交付事件或终止事件，可以开始转发。
	ready bool
	// err 是读到的错误；上游在首段有效输出之前结束也算错误。
	err error
	// timeout 表示等待首字的时间用完，调用方据此区分来源太慢与本轮预算用完。
	timeout bool
}

// readPrelude 读到第一个可交付事件为止，把经过的字节原样存下来。一次读一块，
// 已经读到的字节全部保留：读一块时可能顺带读到后面的事件，丢掉就会让客户端少
// 事件。上限按字节计，达到上限时返回已经读到的内容，由调用方决定放行。
func readPrelude(body io.Reader, limit int) prelude {
	var buf []byte
	chunk := make([]byte, 16<<10)
	scanned := 0
	for {
		n, err := body.Read(chunk)
		if n > 0 {
			buf = append(buf, chunk[:n]...)
			var ready bool
			ready, scanned = preludeReady(buf, scanned)
			if ready {
				return prelude{buf: buf, ready: true}
			}
			if len(buf) >= limit {
				return prelude{buf: buf}
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				return prelude{buf: buf, err: io.ErrUnexpectedEOF}
			}
			return prelude{buf: buf, err: err}
		}
	}
}

// preludeReady 从 scanned 处开始扫完整的事件行，报告是否出现可交付事件；返回值
// scanned 是下次继续扫描的位置，末尾不完整的一行留给后续读取。
func preludeReady(buf []byte, scanned int) (bool, int) {
	for {
		end := bytes.IndexByte(buf[scanned:], '\n')
		if end < 0 {
			return false, scanned
		}
		end += scanned
		line := buf[scanned:end]
		scanned = end + 1
		trimmed := bytes.TrimRight(line, "\r")
		if data, ok := bytes.CutPrefix(trimmed, []byte("data:")); ok {
			if firstOutputStreamEvent(bytes.TrimSpace(data)) {
				return true, scanned
			}
		}
	}
}

// gateFirstOutput 读到首个有效输出为止，返回暂存的字节与原因。wait 是这一次尝试
// 剩余的首字时间，到点后关闭上游响应体，阻塞中的读取随即返回。这一阶段还没有向
// 客户端写出任何字节，失败时可以换下一条候选。
func (p *Proxy) gateFirstOutput(body io.ReadCloser, wait time.Duration) prelude {
	done := make(chan prelude, 1)
	go func() { done <- readPrelude(body, maxPreludeBytes) }()
	if wait <= 0 {
		_ = body.Close()
		got := <-done
		got.timeout = true
		return got
	}
	timer := time.AfterFunc(wait, func() { _ = body.Close() })
	defer timer.Stop()
	select {
	case got := <-done:
		return got
	case <-timer.C:
		got := <-done
		// 时间到点时内容可能恰好已经读到，读到了仍然照常交付。
		got.timeout = !got.ready
		return got
	}
}

// firstOutputStreamEvent 报告这个 SSE 事件是否已经可以交给客户端：正文、拒答、
// 工具参数、工具调用条目与任何终止事件都算首段有效输出；response.created、
// response.in_progress 与心跳只算开场，继续暂存。数据不是 JSON 时按可以交付处理，
// 交给后面按错误响应结束，而不是继续等下去。
func firstOutputStreamEvent(data []byte) bool {
	if len(data) == 0 {
		return false
	}
	if bytes.Equal(data, []byte("[DONE]")) {
		return true
	}
	var event struct {
		Type  string `json:"type"`
		Delta string `json:"delta"`
	}
	if err := json.Unmarshal(data, &event); err != nil {
		return true
	}
	switch event.Type {
	case "response.output_text.delta", "response.refusal.delta":
		return event.Delta != ""
	case "response.function_call_arguments.delta",
		"response.output_item.added", "response.output_item.done",
		"response.completed", "response.incomplete", "response.failed",
		"error", "response.error":
		return true
	default:
		return false
	}
}

// prefixed 先返回首个有效输出之前暂存的字节，再接着读上游响应体；关闭时一并
// 关闭上游，连接与取消照常归还。
type prefixed struct {
	head *bytes.Reader
	body io.ReadCloser
}

func (p *prefixed) Read(b []byte) (int, error) {
	if p.head != nil && p.head.Len() > 0 {
		return p.head.Read(b)
	}
	if p.body == nil {
		return 0, io.EOF
	}
	return p.body.Read(b)
}

func (p *prefixed) Close() error {
	if p.body == nil {
		return nil
	}
	err := p.body.Close()
	p.body = nil
	return err
}
