package llmproxy

import "encoding/json"

// estimateLlmTextTokens 按字符类型估算一段文字的 token 数，口径与客户端
// app/lib/ai/llm_context_budget.dart 的 estimateLlmTextTokens 相同：兼容接口没有
// 共用的 tokenizer，中文一字约 0.6 到 1 个 token，ASCII 约三个字符一个 token，
// 辅助平面的字符按两个计。两端用同一套算法，预留与客户端发请求前的判断才不会
// 各算各的；改这里时要同时改客户端。
func estimateLlmTextTokens(text string) int64 {
	var ascii, tokens int64
	for _, r := range text {
		switch {
		case r < 128:
			ascii++
		case r > 0xffff:
			tokens += 2
		default:
			tokens++
		}
	}
	return tokens + (ascii+2)/3
}

// estimatedImageTokens 是一张内联图片在预留里占的 token 数。图片以 base64
// 内联在请求里，编码后的字节数是原图的三分之一以上，按字节算会让一张 500 KB
// 的照片单独超过整天的免费额度；客户端也按 2048 计，两端同值。
const estimatedImageTokens = 2048

// maxReservedOutputTokens 是预留时给输出留的上限。客户端允许把输出上限请求到
// 32768，但实际回答多在数千 token；按上限全额乘四会先占掉一大截额度，结算时再
// 退回，靠近额度末尾的请求因此被误拒。预留只按常见长度占位，超出部分在结算时
// 按来源报告的 usage 补记。
const maxReservedOutputTokens = 4096

// reservedOutput 返回一次请求在预留里按多少输出 token 计。
func reservedOutput(output int64) int64 {
	return min(output, maxReservedOutputTokens)
}

// estimateChatInput 按客户端 LlmContextBudget 的口径估算一次对话请求的输入：
// 指令、工具定义、每条输入的文字、函数调用与工具结果都按字符估算，图片每张按
// 固定值计。image_url 里的 base64 不按文字读，否则一张照片就能把估算抬到整天的
// 额度以上。
func estimateChatInput(fields map[string]json.RawMessage) int64 {
	total := int64(32)
	total += estimateLlmTextTokens(decodeString(fields["instructions"]))
	if raw, ok := fields["tools"]; ok {
		total += estimateLlmTextTokens(string(raw))
	}
	var items []struct {
		Type      string          `json:"type"`
		Content   json.RawMessage `json:"content"`
		Output    json.RawMessage `json:"output"`
		CallID    string          `json:"call_id"`
		Name      string          `json:"name"`
		Arguments string          `json:"arguments"`
	}
	if json.Unmarshal(fields["input"], &items) != nil {
		return total
	}
	for _, item := range items {
		// 一条输入条目自身的包装：角色、类型与 id 这类字段。
		total += 16
		switch item.Type {
		case "function_call":
			total += 20 + estimateLlmTextTokens(item.CallID) +
				estimateLlmTextTokens(item.Name) + estimateLlmTextTokens(item.Arguments)
		case "function_call_output":
			total += estimateLlmTextTokens(item.CallID) + estimateLlmContent(item.Output)
		default:
			total += estimateLlmContent(item.Content)
		}
	}
	return total
}

// estimateLlmContent 估算一个 content 或 output 字段：字符串按文字算，片段数组
// 按 input_text 的文字与 input_image 的固定值算；其他形式按原始 JSON 文本算。
func estimateLlmContent(raw json.RawMessage) int64 {
	var text string
	if err := json.Unmarshal(raw, &text); err == nil {
		return estimateLlmTextTokens(text)
	}
	var parts []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(raw, &parts); err == nil {
		var total int64
		for _, part := range parts {
			if part.Type == "input_image" {
				total += estimatedImageTokens
				continue
			}
			total += estimateLlmTextTokens(part.Text)
		}
		return total
	}
	return estimateLlmTextTokens(string(raw))
}

// estimateResponseOutput 估算整段响应里的输出 token，按输出条目的正文与工具
// 参数计。来源返回 2xx 却没有报告 usage 时用它结算，不沿用预留量。
func estimateResponseOutput(output []map[string]json.RawMessage) int64 {
	var total int64
	for _, item := range output {
		var content []struct {
			Type    string `json:"type"`
			Text    string `json:"text"`
			Refusal string `json:"refusal"`
		}
		if raw, ok := item["content"]; ok && json.Unmarshal(raw, &content) == nil {
			for _, part := range content {
				total += estimateLlmTextTokens(part.Text)
				total += estimateLlmTextTokens(part.Refusal)
			}
		}
		total += estimateLlmTextTokens(decodeString(item["arguments"]))
		total += estimateLlmTextTokens(decodeString(item["name"]))
	}
	return total
}

// streamOutputTokens 估算一条流事件带来的输出 token。只数增量事件：完整条目与
// 结束事件里的正文已经由增量累加过，再数一遍会重复。
func streamOutputTokens(data []byte) int64 {
	var event struct {
		Type  string `json:"type"`
		Delta string `json:"delta"`
	}
	if json.Unmarshal(data, &event) != nil {
		return 0
	}
	switch event.Type {
	case "response.output_text.delta", "response.refusal.delta",
		"response.function_call_arguments.delta":
		return estimateLlmTextTokens(event.Delta)
	}
	return 0
}

// decodeString 读一个 JSON 字符串字段；不是字符串或没有值时返回空串。
func decodeString(raw json.RawMessage) string {
	var text string
	if len(raw) == 0 || json.Unmarshal(raw, &text) != nil {
		return ""
	}
	return text
}
