package llmproxy

import (
	"encoding/json"
	"strings"
	"testing"
)

// TestEstimateLlmTextTokens 核对字符估算与客户端 estimateLlmTextTokens 同口径：
// 非 ASCII 每个记 1，ASCII 每三个记 1，辅助平面的字符记 2。
func TestEstimateLlmTextTokens(t *testing.T) {
	cases := map[string]int64{
		"":      0,
		"abc":   1,
		"abcd":  2,
		"中文":    2,
		"中文abc": 3,
		"😀":     2,
	}
	for text, want := range cases {
		if got := estimateLlmTextTokens(text); got != want {
			t.Errorf("estimateLlmTextTokens(%q) = %d，期望 %d", text, got, want)
		}
	}
}

// TestEstimateChatInput 核对输入估算按指令、条目、工具调用与图片计数，图片按
// 固定值而不是 base64 长度。
func TestEstimateChatInput(t *testing.T) {
	fields := decodeFields(t, `{
		"model": "zhixin-chat",
		"instructions": "按步骤回答",
		"input": [
			{"type": "message", "role": "user", "content": "你好"},
			{"type": "message", "role": "user", "content": [
				{"type": "input_text", "text": "看图"},
				{"type": "input_image", "image_url": "data:image/jpeg;base64,AAAA"}
			]},
			{"type": "function_call", "call_id": "c1", "name": "lookup", "arguments": "{}"},
			{"type": "function_call_output", "call_id": "c1", "output": "{\"result\":\"ok\"}"}
		],
		"max_output_tokens": 16384
	}`)
	const want = int64(32 + 5 + (16 + 2) + (16 + 2 + 2048) + (16 + 20 + 1 + 2 + 1) + (16 + 1 + 5))
	if got := estimateChatInput(fields); got != want {
		t.Fatalf("输入估算应为 %d，得到 %d", want, got)
	}

	// 把图片的 base64 换成 1 MB，估算不变。
	long := strings.Repeat("A", 1<<20)
	big := decodeFields(t, `{
		"input": [{"type": "message", "role": "user", "content": [
			{"type": "input_text", "text": "看图"},
			{"type": "input_image", "image_url": "data:image/jpeg;base64,`+long+`"}
		]}]
	}`)
	const smallWant = int64(32 + (16 + 2 + 2048))
	if got := estimateChatInput(big); got != smallWant {
		t.Fatalf("图片应按每张 2048 计，得到 %d", got)
	}
}

// TestReservedOutput 核对输出预留按常见长度占位，不按请求的上限全额乘四。
func TestReservedOutput(t *testing.T) {
	for _, call := range []struct{ output, want int64 }{
		{0, 0}, {100, 100}, {4096, 4096}, {16384, 4096}, {32768, 4096},
	} {
		if got := reservedOutput(call.output); got != call.want {
			t.Errorf("reservedOutput(%d) = %d，期望 %d", call.output, got, call.want)
		}
	}
}

// TestEstimateStreamOutput 核对流事件只累计增量，完整条目与结束事件不重复计。
func TestEstimateStreamOutput(t *testing.T) {
	if got := streamOutputTokens([]byte(`{"type":"response.output_text.delta","delta":"你好"}`)); got != 2 {
		t.Fatalf("增量应计 2，得到 %d", got)
	}
	if got := streamOutputTokens([]byte(`{"type":"response.completed","response":{"output":[]}}`)); got != 0 {
		t.Fatalf("结束事件不应再计正文，得到 %d", got)
	}
	if got := streamOutputTokens([]byte(`{"type":"response.function_call_arguments.delta","delta":"{}"}`)); got != 1 {
		t.Fatalf("工具参数增量应计 1，得到 %d", got)
	}
}

// TestEstimateResponseOutput 核对整段响应的输出估算按正文与工具参数计。
func TestEstimateResponseOutput(t *testing.T) {
	var response struct {
		Output []map[string]json.RawMessage `json:"output"`
	}
	body := `{"output":[
		{"type":"message","content":[{"type":"output_text","text":"你好"}]},
		{"type":"function_call","arguments":"{}"}
	]}`
	if err := json.Unmarshal([]byte(body), &response); err != nil {
		t.Fatal(err)
	}
	if got := estimateResponseOutput(response.Output); got != 3 {
		t.Fatalf("输出估算应为 3，得到 %d", got)
	}
}

func decodeFields(t *testing.T, body string) map[string]json.RawMessage {
	t.Helper()
	var fields map[string]json.RawMessage
	if err := json.Unmarshal([]byte(body), &fields); err != nil {
		t.Fatalf("解析请求体: %v", err)
	}
	return fields
}
