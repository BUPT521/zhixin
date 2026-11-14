// Package llmproxy 的 HTTP 入口：路由由内部/api 的生成代码提供。
//
// 聊天补全按 SSE 边收边发，因此这里保留 http.ResponseWriter 形态的处理器，
// 不走 oapi-codegen 的严格服务接口（ADR-0015 第 4 条记录了这处取舍）。
package llmproxy

import "net/http"

// ModelsHTTP 处理 GET /v1/llm/models。
func (p *Proxy) ModelsHTTP(w http.ResponseWriter, r *http.Request) { p.models(w, r) }

// QuotaHTTP 处理 GET /v1/llm/quota。
func (p *Proxy) QuotaHTTP(w http.ResponseWriter, r *http.Request) { p.quotaStatus(w, r) }

// ChatHTTP 处理 POST /v1/llm/chat/completions。
func (p *Proxy) ChatHTTP(w http.ResponseWriter, r *http.Request) { p.chat(w, r) }
