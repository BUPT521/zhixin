package llmproxy

import (
	"bytes"
	"encoding/json"
)

// requiredCapabilities 从已经通过白名单与类型校验的请求体判断这次请求需要什么
// 能力：`tools` 非空表示要用函数调用，输入条目的 content 里出现 `input_image`
// 表示要读图片。其余字段与嵌入请求都不要求额外能力。
func requiredCapabilities(fields map[string]json.RawMessage) capabilities {
	var need capabilities
	if raw, ok := fields["tools"]; ok {
		var tools []json.RawMessage
		if json.Unmarshal(raw, &tools) == nil && len(tools) > 0 {
			need.tools = true
		}
	}
	raw, ok := fields["input"]
	if !ok {
		return need
	}
	var items []struct {
		Content json.RawMessage `json:"content"`
	}
	if json.Unmarshal(raw, &items) != nil {
		return need
	}
	for _, item := range items {
		if contentHasImage(item.Content) {
			need.images = true
			break
		}
	}
	return need
}

// contentHasImage 报告一个消息条目的 content 里有没有图片片段。content 可能是
// 字符串，也可能是 input_text、input_image 等片段组成的数组；只有数组里出现
// `input_image` 才算带图片。
func contentHasImage(raw json.RawMessage) bool {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || trimmed[0] != '[' {
		return false
	}
	var parts []struct {
		Type string `json:"type"`
	}
	if json.Unmarshal(trimmed, &parts) != nil {
		return false
	}
	for _, part := range parts {
		if part.Type == "input_image" {
			return true
		}
	}
	return false
}

// modelSupports 报告模型是否配置了具备所需能力的路由，不看健康状态与启用：用来
// 区分“根本没有这种能力”和“有但都在冷却”。
func modelSupports(m *liveModel, need capabilities) bool {
	if !need.tools && !need.images {
		return true
	}
	for _, rt := range m.Live {
		if need.tools && !rt.SupportsTools {
			continue
		}
		if need.images && !rt.SupportsImages {
			continue
		}
		return true
	}
	return false
}

// capabilityDetail 是能力缺失时给客户端的说明，只写缺哪一种能力，不带配置细节。
func capabilityDetail(need capabilities) string {
	switch {
	case need.images && need.tools:
		return "no configured model route supports images and tool calls"
	case need.images:
		return "no configured model route supports image input"
	default:
		return "no configured model route supports tool calls"
	}
}
