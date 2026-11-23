package llmproxy

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"sync"
)

// EmbeddingCache 是按账号隔离的嵌入向量缓存（ADR-0030）。检索索引由客户端维护，
// 服务端只保存“模型与文本哈希到向量”这一层，用来消掉换机、重建与切换模型时的
// 重复嵌入。缓存是派生数据：可以从业务库与嵌入服务重建，不进入数据包与整库
// 备份，随清除云端数据与删除账号一起删除。
//
// 键是账号、对外模型名与文本哈希；同名模型必须保持同一个向量空间，换部署要换
// 对外模型名，改维度要删掉这个模型的缓存行，见 ADR-0029。
//
// 清除云端数据与写入之间用账号的代次排除竞争（ADR-0037）：嵌入请求在调用来源
// 之前读一次代次，写入时由实现在自己的事务里再读一次比较，对不上说明期间清空过
// 一次，这次写入丢弃；清除时把代次加一并删行，两步在同一把账号锁内完成。
type EmbeddingCache interface {
	// Lookup 返回这个账号与模型下已有的向量，并按命中更新 last_used_at。没有
	// 命中的哈希不出现在结果里；顺序由实现决定，调用方按哈希自己对应。
	Lookup(ctx context.Context, userID, model string, hashes []string) ([]CachedVector, error)
	// Put 写入一批向量，已经存在的行保持原值。写入之后按账号的字节上限删除最久
	// 未用的行。expectedGeneration 是请求开始时读到的代次；事务内当前代次与它
	// 不一致时放弃这次写入并返回 nil，因为这次算出的向量属于清除之前的数据。
	Put(ctx context.Context, userID, model string, items []CachedVector, expectedGeneration int64) error
	// DeleteModel 删除一个对外模型的全部缓存行；管理后台删除模型或改变维度时调用。
	DeleteModel(ctx context.Context, model string) error
	// DeleteUser 删除一个账号的全部缓存行；删除账号时调用，行随外键级联。
	DeleteUser(ctx context.Context, userID string) error
	// Generation 返回账号当前的缓存代次；没有清空过时是 0。嵌入请求在调用来源
	// 之前读一次，写入时传回 Put 比较。
	Generation(ctx context.Context, userID string) (int64, error)
	// PurgeUser 原子地删除账号的全部缓存行并把代次加一；清除云端数据时调用。
	PurgeUser(ctx context.Context, userID string) error
}

// CachedVector 是一行缓存：文本哈希、维度与小端序 FP16 的向量。
type CachedVector struct {
	Hash   string
	Dim    int
	Vector []byte
}

// cacheLimits 是缓存实现接收每账号字节上限的约定：上限只有配置一处来源，装配
// 时由 Proxy 注入。内存与 PostgreSQL 两种实现都实现这个方法。
type cacheLimits interface {
	SetEmbeddingCacheLimit(bytes int64)
}

// textHash 返回片段文本按 UTF-8 字节计算的 SHA-256 小写十六进制。客户端与服务端
// 对同一段文本使用同一口径：切片与规范化只在客户端做一次，两边不再额外处理。
func textHash(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

// encodeVector 把浮点数组转成小端序 FP16。缓存与查找接口都用这个格式，客户端
// 解码之后按现有方式归一化。
func encodeVector(v []float32) []byte {
	out := make([]byte, len(v)*2)
	for i, f := range v {
		binary.LittleEndian.PutUint16(out[i*2:], float32ToFloat16(f))
	}
	return out
}

// decodeVector 把 FP16 小端序还原成浮点数组；查找接口的测试与排查用它核对往返。
func decodeVector(b []byte) ([]float32, error) {
	if len(b)%2 != 0 {
		return nil, errors.New("llmproxy: FP16 向量长度不是偶数")
	}
	out := make([]float32, len(b)/2)
	for i := range out {
		out[i] = float16ToFloat32(binary.LittleEndian.Uint16(b[i*2:]))
	}
	return out, nil
}

// float32ToFloat16 按 IEEE 754 把 float32 转成 float16，舍入为就近取偶。溢出按
// 正负无穷处理，下溢到 0；向量的分量在这个范围内，NaN 只在提供方返回坏数据时
// 出现，照实写成 NaN，不悄悄换成 0。
func float32ToFloat16(f float32) uint16 {
	bits := math.Float32bits(f)
	sign := uint16(bits>>16) & 0x8000
	exp := int((bits >> 23) & 0xff)
	mant := bits & 0x7fffff
	switch {
	case exp == 0xff:
		if mant != 0 {
			return sign | 0x7e00 // NaN
		}
		return sign | 0x7c00 // Inf
	}
	e := exp - 127 + 15
	if e >= 0x1f {
		return sign | 0x7c00
	}
	if e <= 0 {
		if e < -10 {
			return sign
		}
		mant |= 0x800000
		shift := uint(14 - e)
		half := mant >> shift
		rem := mant & (1<<shift - 1)
		halfway := uint32(1) << (shift - 1)
		if rem > halfway || (rem == halfway && half&1 == 1) {
			half++
		}
		return sign | uint16(half)
	}
	half := uint16(e)<<10 | uint16(mant>>13)
	rem := mant & 0x1fff
	if rem > 0x1000 || (rem == 0x1000 && half&1 == 1) {
		half++
	}
	return sign | half
}

// float16ToFloat32 把 float16 还原成 float32，供测试核对往返。用浮点运算拼出
// 数值，省掉逐位移位的规范化，读起来与 IEEE 754 的定义一致。
func float16ToFloat32(h uint16) float32 {
	exp := int((h >> 10) & 0x1f)
	mant := int(h & 0x3ff)
	var f float64
	switch exp {
	case 0:
		f = math.Ldexp(float64(mant), -24)
	case 0x1f:
		if mant != 0 {
			return math.Float32frombits(uint32(h&0x8000)<<16 | 0x7fc00000)
		}
		f = math.Inf(1)
	default:
		f = math.Ldexp(1+float64(mant)/1024, exp-15)
	}
	if h&0x8000 != 0 {
		f = -f
	}
	return float32(f)
}

// parseEmbedding 把提供方返回的一条向量解成浮点数。OpenAI 兼容接口默认返回浮点
// 数组，请求带 encoding_format=base64 时返回小端序 FP32 的 base64；两种都要能
// 写进缓存，因为客户端可以自己指定编码格式。
func parseEmbedding(raw json.RawMessage) ([]float32, error) {
	t := bytes.TrimSpace(raw)
	if len(t) == 0 || bytes.Equal(t, []byte("null")) {
		return nil, errors.New("llmproxy: 向量为空")
	}
	if t[0] == '[' {
		var v []float32
		if err := json.Unmarshal(t, &v); err != nil {
			return nil, fmt.Errorf("llmproxy: 向量不是浮点数组: %w", err)
		}
		return v, nil
	}
	var s string
	if err := json.Unmarshal(t, &s); err != nil {
		return nil, errors.New("llmproxy: 向量既不是浮点数组也不是 base64 字符串")
	}
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		b, err = base64.RawStdEncoding.DecodeString(s)
	}
	if err != nil {
		return nil, errors.New("llmproxy: 向量的 base64 不合法")
	}
	if len(b) == 0 || len(b)%4 != 0 {
		return nil, errors.New("llmproxy: base64 向量的长度不是 FP32 的整数倍")
	}
	out := make([]float32, len(b)/4)
	for i := range out {
		out[i] = math.Float32frombits(binary.LittleEndian.Uint32(b[i*4:]))
	}
	return out, nil
}

// MemoryEmbeddingCache 是进程内的 EmbeddingCache，用于本地联调与测试。行按
// 账号、模型与哈希分开保存，上限按这些行的向量字节合计淘汰最久未用的行；代次
// 与行共用同一把锁，清除与写入因此在本进程内是串行的。
type MemoryEmbeddingCache struct {
	mu    sync.Mutex
	limit int64
	seq   uint64
	used  int64
	rows  map[memoryCacheKey]*memoryCacheRow
	// gens 是每个账号的缓存代次，清除云端数据时加一。账号 id 不复用，删号清理
	// 不回收这里的键。
	gens map[string]int64
}

type memoryCacheKey struct{ userID, model, hash string }

type memoryCacheRow struct {
	dim    int
	vector []byte
	usedAt uint64
}

// NewMemoryEmbeddingCache 建一份空的进程内缓存；上限由装配时的
// SetEmbeddingCacheLimit 注入，0 表示不限制。
func NewMemoryEmbeddingCache() *MemoryEmbeddingCache {
	return &MemoryEmbeddingCache{
		rows: map[memoryCacheKey]*memoryCacheRow{},
		gens: map[string]int64{},
	}
}

// SetEmbeddingCacheLimit 注入每账号的字节上限；由 Proxy 装配时调用。改为更小的
// 上限时下一次写入才淘汰，读路径不因为改配置而变慢。
func (m *MemoryEmbeddingCache) SetEmbeddingCacheLimit(bytes int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.limit = bytes
}

func (m *MemoryEmbeddingCache) Lookup(_ context.Context, userID, model string, hashes []string) ([]CachedVector, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]CachedVector, 0, len(hashes))
	seen := make(map[string]bool, len(hashes))
	for _, h := range hashes {
		if seen[h] {
			continue
		}
		seen[h] = true
		row, ok := m.rows[memoryCacheKey{userID, model, h}]
		if !ok {
			continue
		}
		m.seq++
		row.usedAt = m.seq
		out = append(out, CachedVector{Hash: h, Dim: row.dim, Vector: row.vector})
	}
	return out, nil
}

func (m *MemoryEmbeddingCache) Put(_ context.Context, userID, model string, items []CachedVector, expectedGeneration int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	// 代次对不上说明请求开始之后清空过一次，这次算出的向量属于清除之前的数据，
	// 丢掉而不是写回缓存。
	if m.gens[userID] != expectedGeneration {
		return nil
	}
	for _, item := range items {
		key := memoryCacheKey{userID, model, item.Hash}
		if _, ok := m.rows[key]; ok {
			continue // 已经算过的行不覆盖
		}
		m.seq++
		row := &memoryCacheRow{dim: item.Dim, vector: item.Vector, usedAt: m.seq}
		m.rows[key] = row
		m.used += int64(len(row.vector))
	}
	m.trimLocked(userID)
	return nil
}

// trimLocked 按 last_used_at 淘汰这个账号最久的行，直到回到上限之内。调用方必须
// 持有 m.mu。
func (m *MemoryEmbeddingCache) trimLocked(userID string) {
	if m.limit <= 0 {
		return
	}
	for m.userBytesLocked(userID) > m.limit {
		var oldestKey memoryCacheKey
		var oldest *memoryCacheRow
		for key, row := range m.rows {
			if key.userID != userID {
				continue
			}
			if oldest == nil || row.usedAt < oldest.usedAt {
				oldestKey, oldest = key, row
			}
		}
		if oldest == nil {
			return
		}
		delete(m.rows, oldestKey)
		m.used -= int64(len(oldest.vector))
	}
}

// userBytesLocked 汇总一个账号的向量字节。调用方必须持有 m.mu。
func (m *MemoryEmbeddingCache) userBytesLocked(userID string) int64 {
	var total int64
	for key, row := range m.rows {
		if key.userID == userID {
			total += int64(len(row.vector))
		}
	}
	return total
}

func (m *MemoryEmbeddingCache) DeleteModel(_ context.Context, model string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for key, row := range m.rows {
		if key.model == model {
			delete(m.rows, key)
			m.used -= int64(len(row.vector))
		}
	}
	return nil
}

func (m *MemoryEmbeddingCache) DeleteUser(_ context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.removeUserRowsLocked(userID)
	return nil
}

// Generation 返回账号当前的缓存代次；还没有清空过时是 0。
func (m *MemoryEmbeddingCache) Generation(_ context.Context, userID string) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.gens[userID], nil
}

// PurgeUser 删除账号的全部缓存行并把代次加一；两步在同一把锁内完成，写入方在
// 别处读到的代次与这里加一之间的顺序因此是确定的。
func (m *MemoryEmbeddingCache) PurgeUser(_ context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.gens[userID]++
	m.removeUserRowsLocked(userID)
	return nil
}

// removeUserRowsLocked 删除一个账号的全部行并更新字节合计。调用方必须持有 m.mu。
func (m *MemoryEmbeddingCache) removeUserRowsLocked(userID string) {
	for key, row := range m.rows {
		if key.userID == userID {
			delete(m.rows, key)
			m.used -= int64(len(row.vector))
		}
	}
}

// Bytes 返回当前保存的向量字节合计，供测试核对上限淘汰。
func (m *MemoryEmbeddingCache) Bytes() int64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.used
}

var (
	_ EmbeddingCache = (*MemoryEmbeddingCache)(nil)
	_ cacheLimits    = (*MemoryEmbeddingCache)(nil)
)
