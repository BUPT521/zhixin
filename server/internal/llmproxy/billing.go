package llmproxy

// 计费 token 的折算口径。
//
// 上游按输入是否命中上下文缓存分开计价，命中与未命中的单价差到五十倍（DeepSeek
// 谷价每百万 token：命中输入 0.003、未命中输入 0.15、输出 0.6 美元），所以额度
// 与已购余额不能按“一个 token 顶一个 token”扣，否则全是缓存命中的账号与全是
// 未命中的账号付一样的钱，而前者的成本只有后者的五十分之一。
//
// 权重以“一个未命中输入的 token”为 1：命中缓存的输入记 1/50，输出记 4。乘以
// 分母 50 之后全是整数，按 fiftieths 累加再四舍五入成整 token，单次调用的误差
// 不超过半个 token，相对一次对话的用量可以忽略。
const (
	billedScale    = 50
	billedHitUnit  = 1
	billedMissUnit = billedScale
	billedOutUnit  = 4 * billedScale
)

// Usage 是一次调用的用量。Input 与 Cached 是来源报告的输入量与其中命中上下文
// 缓存的部分，Output 是输出量。来源只报总量时 Input 与 Cached 为 0，此时按原始
// token 记账，见 Billed。
//
// CachedReported 记录来源这次有没有给出 cached_tokens。给了而值为 0 表示这次确实
// 没有命中，没有给表示这次拿不到命中数据；后台统计把两者分开，因为把缺报当成
// 零命中会让命中率偏低，据此判断路由好坏就会判断错。它只用于统计，不参与折算。
type Usage struct {
	Input, Cached, Output int64
	CachedReported        bool
}

func (u Usage) Total() int64 { return u.Input + u.Output }

// Billed 将原始用量折算成计费 token。嵌入输入按 1:1 折算，以百炼
// text-embedding-v4 的实时输入价与萤火档的积分单价为基准（ADR-0084）。
// 聊天来源缺少用量拆分时也按原始 token 计，避免将无法区分的输入算成输出。
func (u Usage) Billed(kind Kind) int64 {
	if kind == KindEmbedding || u.Input <= 0 {
		return u.Total()
	}
	cached := min(max(u.Cached, 0), u.Input)
	miss := u.Input - cached
	output := max(u.Output, 0)
	units := miss*billedMissUnit + cached*billedHitUnit + output*billedOutUnit
	return (units + billedScale/2) / billedScale
}

// reserve 是这次用量在预留阶段该占的计费 token 数；标注为估算时按同一口径折算，
// 估算里的输入一律当作未命中缓存，宁可多留一点。
func (u Usage) reserve(kind Kind) int64 {
	if kind == KindEmbedding {
		return u.Total()
	}
	return (u.Input*billedMissUnit + u.Output*billedOutUnit + billedScale/2) / billedScale
}
