package llmproxy

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"
)

// maxPreludeBytes 是首个有效输出之前最多暂存的字节数。
const maxPreludeBytes = 64 << 10

var errPreludeTooLarge = errors.New("首个有效输出前的流事件超过上限")

// prelude 是流式响应在首个有效输出之前读到的事件与读到的结果。
type prelude struct {
	// buf 是已经读到的原始字节，确认可以交付之后原样转发。
	buf []byte
	// ready 表示已经读到可以交付的正文、拒答、完整工具调用或截断事件。
	ready bool
	// failure 是交付之前收到的终止事件，供调用方判断失败类型和结算用量。
	failure []byte
	// err 是读到的错误；上游在首段有效输出之前结束也算错误。
	err error
	// timeout 表示等待首字的时间用完，调用方据此区分来源太慢与本轮预算用完。
	timeout bool
}

// readPrelude 读到第一个可交付事件为止，把经过的字节原样存下来。一次读一块，
// 已经读到的字节全部保留：读一块时可能顺带读到后面的事件，丢掉就会让客户端少
// 事件。达到字节上限仍没有可交付事件时结束这次尝试。
func readPrelude(body io.Reader, limit int) prelude {
	buf := make([]byte, 0, limit)
	chunk := make([]byte, 16<<10)
	scanned := 0
	for len(buf) < limit {
		n, err := body.Read(chunk[:min(len(chunk), limit-len(buf))])
		if n > 0 {
			buf = append(buf, chunk[:n]...)
			var ready bool
			var failure []byte
			ready, failure, scanned = preludeReady(buf, scanned)
			if ready {
				return prelude{buf: buf, ready: true}
			}
			if failure != nil {
				return prelude{failure: failure}
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				return prelude{buf: buf, err: io.ErrUnexpectedEOF}
			}
			return prelude{err: err}
		}
	}
	return prelude{err: errPreludeTooLarge}
}

// preludeReady 从 scanned 处开始扫完整的事件行，报告是否出现可交付事件；返回值
// scanned 是下次继续扫描的位置，末尾不完整的一行留给后续读取。
func preludeReady(buf []byte, scanned int) (bool, []byte, int) {
	for {
		end := bytes.IndexByte(buf[scanned:], '\n')
		if end < 0 {
			return false, nil, scanned
		}
		end += scanned
		line := buf[scanned:end]
		scanned = end + 1
		trimmed := bytes.TrimRight(line, "\r")
		if data, ok := bytes.CutPrefix(trimmed, []byte("data:")); ok {
			data = bytes.TrimSpace(data)
			ready, failed := firstOutputStreamEvent(data)
			if ready {
				return true, nil, scanned
			}
			if failed {
				return false, data, scanned
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
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case got := <-done:
		return got
	case <-timer.C:
		_ = body.Close()
		got := <-done
		got.timeout = !got.ready && got.failure == nil
		return got
	}
}

// firstOutputStreamEvent 区分可交付事件与交付前的失败。工具参数增量先暂存，
// 收到完整函数条目之后才交付，避免把尚不能执行的参数绑定到当前来源。
func firstOutputStreamEvent(data []byte) (ready, failed bool) {
	if len(data) == 0 {
		return false, false
	}
	if bytes.Equal(data, []byte("[DONE]")) {
		return false, true
	}
	var event struct {
		Type  string          `json:"type"`
		Delta string          `json:"delta"`
		Error json.RawMessage `json:"error"`
		Item  struct {
			Type      string `json:"type"`
			Name      string `json:"name"`
			Arguments string `json:"arguments"`
			Content   []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"item"`
	}
	if err := json.Unmarshal(data, &event); err != nil || (len(event.Error) > 0 && !bytes.Equal(event.Error, []byte("null"))) {
		return false, true
	}
	switch event.Type {
	case "response.output_text.delta", "response.refusal.delta":
		return event.Delta != "", false
	case "response.output_item.done":
		switch event.Item.Type {
		case "function_call":
			return event.Item.Name != "" && json.Valid([]byte(event.Item.Arguments)), false
		case "message":
			for _, part := range event.Item.Content {
				if part.Type == "output_text" && part.Text != "" {
					return true, false
				}
			}
		}
	case "response.incomplete":
		end, _ := streamData(data)
		return end == responseOutputLimit, end != responseOutputLimit
	case "response.completed", "response.failed",
		"error", "response.error":
		return false, true
	}
	return false, false
}

func preludeFailure(data []byte, retryAfter string) (attemptResult, int, healthOutcome) {
	end, used := streamData(data)
	result := attemptResult{tokens: used.tokens, inputTokens: used.input, cachedTokens: used.cached}
	if result.tokens <= 0 {
		result.tokens = -1
	}
	type upstreamError struct {
		Code string `json:"code"`
	}
	var event struct {
		upstreamError
		Error    upstreamError `json:"error"`
		Response struct {
			Error upstreamError `json:"error"`
		} `json:"response"`
	}
	_ = json.Unmarshal(data, &event)
	for _, code := range []string{event.Response.Error.Code, event.Error.Code, event.Code} {
		switch code {
		case "invalid_api_key":
			return result, http.StatusUnauthorized, httpFailure(http.StatusUnauthorized, "")
		case "rate_limit_exceeded":
			return result, http.StatusTooManyRequests, httpFailure(http.StatusTooManyRequests, retryAfter)
		}
	}
	outcome := end.outcome()
	if end == responseCompleted {
		outcome = healthOutcome{reason: "流式响应没有正文或完整工具调用", scope: routeFailure}
	}
	outcome.sourceReached = true
	return result, 0, outcome
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
