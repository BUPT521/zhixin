package llmproxy

import (
	"bytes"
	"encoding/json"
	"maps"
	"net/url"
	"strings"
)

// normalizeClientResponses 在校验与额度估算之前转换接入密钥请求。
// 客户端同时发送两种写法时，以对应的 Responses 字段为准。
func normalizeClientResponses(fields map[string]json.RawMessage) {
	if raw := fields["input"]; bytes.HasPrefix(bytes.TrimSpace(raw), []byte(`"`)) {
		fields["input"] = bytes.Join([][]byte{
			[]byte(`[{"type":"message","role":"user","content":`), raw, []byte(`}]`),
		}, nil)
	}
	if _, ok := fields["max_output_tokens"]; !ok {
		for _, alias := range []string{"max_completion_tokens", "max_tokens"} {
			if raw, ok := fields[alias]; ok {
				fields["max_output_tokens"] = raw
				break
			}
		}
	}
	var format struct {
		Type string `json:"type"`
	}
	if json.Unmarshal(fields["response_format"], &format) == nil && (format.Type == "text" || format.Type == "json_object") {
		value, _ := json.Marshal(format)
		fillResponseOption(fields, "text", "format", value)
	}
	if effort := clientReasoningEffort(fields["reasoning_effort"], fields["thinking"]); effort != "" {
		value, _ := json.Marshal(effort)
		fillResponseOption(fields, "reasoning", "effort", value)
	}
}

func clientReasoningEffort(rawEffort, rawThinking json.RawMessage) string {
	effort := decodeString(rawEffort)
	switch effort {
	case "none", "minimal", "low", "medium", "high", "xhigh", "max":
	default:
		effort = ""
	}
	var thinking struct {
		Type string `json:"type"`
	}
	if json.Unmarshal(rawThinking, &thinking) == nil {
		switch thinking.Type {
		case "disabled":
			return "none"
		case "enabled":
			if effort == "" || effort == "none" {
				return "high"
			}
		}
	}
	return effort
}

func fillResponseOption(fields map[string]json.RawMessage, field, option string, value json.RawMessage) {
	options := make(map[string]json.RawMessage)
	if raw, ok := fields[field]; ok {
		if json.Unmarshal(raw, &options) != nil || options == nil {
			return
		}
	}
	if _, exists := options[option]; !exists {
		options[option] = value
		fields[field], _ = json.Marshal(options)
	}
}

// requestFieldsWithModel 复制请求字段，供每次尝试分别转换。
// Responses 接口可能默认保存响应，因此转发时显式关闭保存。
func requestFieldsWithModel(fields map[string]json.RawMessage, model string) map[string]json.RawMessage {
	out := maps.Clone(fields)
	out["model"], _ = json.Marshal(model)
	out["store"] = json.RawMessage("false")
	return out
}

func responsesUpstreamBody(fields map[string]json.RawMessage, route liveRoute, session string) ([]byte, error) {
	out := requestFieldsWithModel(fields, route.UpstreamModel)
	if endpoint, err := url.Parse(route.Provider.BaseURL); err == nil {
		switch strings.ToLower(endpoint.Hostname()) {
		case "api.commandcode.ai":
			if session != "" {
				out["prompt_cache_key"], _ = json.Marshal(session)
			}
		case "api.deepseek.com":
			delete(out, "parallel_tool_calls")
			adaptDeepSeekObject(out, "reasoning", "summary")
			adaptDeepSeekObject(out, "text", "verbosity")
		}
	}
	return json.Marshal(out)
}

// adaptDeepSeekObject 移除 DeepSeek 接受但忽略的提示，并换算推理强度。
func adaptDeepSeekObject(fields map[string]json.RawMessage, field, ignored string) {
	var options map[string]json.RawMessage
	if json.Unmarshal(fields[field], &options) != nil || options == nil {
		return
	}
	delete(options, ignored)
	if field == "reasoning" {
		switch decodeString(options["effort"]) {
		case "minimal":
			options["effort"] = json.RawMessage(`"low"`)
		case "medium", "xhigh":
			options["effort"] = json.RawMessage(`"high"`)
		}
	}
	if len(options) == 0 {
		delete(fields, field)
		return
	}
	fields[field], _ = json.Marshal(options)
}
