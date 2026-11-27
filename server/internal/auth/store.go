package auth

import (
	"context"
	"errors"
	"sort"
	"strings"
	"sync"
	"time"
)

// User is an account. One account holds one person's learning data (ADR-0008).
// 账号本身只保存密码；邮箱这类联系方式各在 user_identity 占一行（ADR-0038）。
type User struct {
	ID           string
	PasswordHash string
	CreatedAt    time.Time
}

// AccountRecord 是管理后台列账号时的一行：账号本身与它的全部登录方式。
// 账号页按创建时间倒序显示，登录方式也按创建时间排列。
type AccountRecord struct {
	User       User
	Identities []Identity
}

// Identity 是账号的一种登录方式。一种联系方式只能属于一个账号，
// (Kind, Identifier) 上有唯一约束；VerifiedAt 为零值表示还没有用验证码确认。
type Identity struct {
	ID         string
	UserID     string
	Kind       string
	Identifier string
	VerifiedAt time.Time
	CreatedAt  time.Time
}

// 登录方式的种类。取值也是 user_identity.kind 的 check 约束；代码现在只写
// email，phone 与 wechat 的位置已经留好。
const (
	KindEmail  = "email"
	KindPhone  = "phone"
	KindWechat = "wechat"
)

// Code purposes. The values are also the auth_code.purpose check constraint.
const (
	// PurposeVerifyContact 确认某一种登录方式；PurposeResetPassword 用于找回密码，
	// 顺带确认收到验证码的那种登录方式。
	PurposeVerifyContact = "verify_contact"
	PurposeResetPassword = "reset_password"
)

// Code is one active verification or password reset code. 验证码按登录方式保存，
// 不挂在账号上：还没有注册的邮箱或手机号也能先发一枚，所以 UserID 允许为空。
// Only the HMAC-SHA256 of the six-digit code is stored; the plain code exists
// only in the message sent to the user.
type Code struct {
	Purpose    string
	Kind       string
	Identifier string
	UserID     string
	CodeHash   string
	ExpiresAt  time.Time
	CreatedAt  time.Time
}

// Session is one signed-in device. Only token hashes are stored.
type Session struct {
	ID             string
	UserID         string
	DeviceName     string
	AccessHash     string
	RefreshHash    string
	AccessExpires  time.Time
	RefreshExpires time.Time
	CreatedAt      time.Time
	// ContactVerified 表示这个账号至少有一种登录方式已经确认；按访问令牌查询
	// 会话时从 user_identity 算出。
	ContactVerified bool
}

// APIKey 是给用户自己的脚本或第三方工具调用模型的一把密钥（ADR-0063）。
// 密钥本身只在签发那一次返回，库里只存 SHA-256；Prefix 是前几位，用于列表展示
// 与撤销时辨认。没有有效期：不过期，只能显式撤销。ContactVerified 只在按摘要
// 鉴权时填充，与访问令牌同一口径（至少一种登录方式确认过）。
type APIKey struct {
	ID      string
	UserID  string
	Name    string
	Prefix  string
	Revoked bool
	// RevokedAt 是撤销的时刻，只在存储层用于每日清理，列表与响应不返回。
	RevokedAt       time.Time
	LastUsedAt      time.Time
	CreatedAt       time.Time
	ContactVerified bool
}

// RefreshUsed 是一次已经轮换掉的刷新令牌摘要。旧令牌再次出现时，服务层用它
// 判断是同一客户端的重试还是令牌被复制：宽限期内且 request_id 一致算重试，
// 其余算盗用。只存摘要，不存令牌本身。
type RefreshUsed struct {
	TokenHash           string
	SessionID           string
	UserID              string
	RequestID           string
	RotatedAt           time.Time
	GraceUntil          time.Time
	ReplacedRefreshHash string
}

// PasswordReset 是一次重设密码要在一个事务（或同一把锁）里做完的四件事：
// 用掉验证码、换密码、把收到验证码的那种登录方式标为已确认、作废该账号的
// 全部会话。收到验证码本身就是这条联系方式属于本人的证据，所以顺带确认它。
type PasswordReset struct {
	UserID          string
	IdentityID      string
	Purpose         string
	Kind            string
	Identifier      string
	ExpectedHash    string
	NewPasswordHash string
	Now             time.Time
}

var (
	ErrNotFound = errors.New("auth: not found")
	// ErrIdentifierTaken 表示这种登录方式已经被别的账号登记。
	ErrIdentifierTaken = errors.New("auth: identifier already registered")
)

// Store persists users, identities and sessions. The PostgreSQL implementation
// follows internal/store/schema.sql; MemoryStore is for development and tests.
type Store interface {
	// CreateAccount 在一个事务（或同一把锁）里写入账号与它的第一种登录方式：
	// 登录方式撞上唯一约束时整个账号都不落地，返回 ErrIdentifierTaken。
	CreateAccount(ctx context.Context, u User, ident Identity) error
	UserByID(ctx context.Context, id string) (User, error)
	// UserByIdentifier 按 (kind, identifier) 找账号；没有登记时返回 ErrNotFound。
	UserByIdentifier(ctx context.Context, kind, identifier string) (User, error)
	// ListAccounts 按创建时间倒序分页列出账号，返回这一页的账号与匹配总数。
	// query 为空时列出全部，否则匹配账号编号或登录方式标识的子串；它只供管理
	// 后台使用，登录与鉴权仍按 (kind, identifier) 精确查找。
	ListAccounts(ctx context.Context, query string, limit, offset int) ([]AccountRecord, int, error)
	// Identities 按创建顺序列出账号的登录方式。
	Identities(ctx context.Context, userID string) ([]Identity, error)
	// Identity 只认这个账号名下的登录方式；编号不存在或属于别的账号时返回
	// ErrNotFound。
	Identity(ctx context.Context, userID, identityID string) (Identity, error)
	// IdentityByIdentifier 按 (kind, identifier) 找登录方式，用于找回密码时定位
	// 收到验证码的那条联系方式；没有登记时返回 ErrNotFound。
	IdentityByIdentifier(ctx context.Context, kind, identifier string) (Identity, error)
	SetIdentityVerified(ctx context.Context, userID, identityID string, at time.Time) error
	// DeleteUser removes the account and, like the schema's ON DELETE CASCADE,
	// its identities and sessions.
	DeleteUser(ctx context.Context, id string) error

	// CreateSession 保存一条会话。maxPerUser 是这个账号保留的会话数上限，
	// 超出时在同一个事务或锁内先删最旧的再插入，并发登录也守得住。
	//
	// expectedPasswordHash 是登录时核对过的密码摘要。非空时，实现要在删除旧
	// 会话与插入新会话的同一个事务或锁里再核对一次账号当前的密码摘要，不一致
	// 返回 ErrInvalidCredentials：登录核对密码与写会话之间如果重设了密码，这次
	// 登录不能发出新会话。空字符串表示不核对，供只写会话的装配与测试使用。
	CreateSession(ctx context.Context, s Session, maxPerUser int, expectedPasswordHash string) error
	SessionByAccessHash(ctx context.Context, hash string) (Session, error)
	SessionByRefreshHash(ctx context.Context, hash string) (Session, error)
	// RotateSessionAndRecord 在同一个事务或同一把锁里完成轮换与重放记录：CAS
	// 换掉会话的两个令牌摘要，再写入旧摘要的重放记录。两步一起成功或一起不发
	// 生，刷新因此没有“令牌换了但重放记录没写入”的中间状态：写记录失败时会话
	// 保持原样，客户端拿旧令牌重试即可，不会既拿不到新令牌又失去旧令牌。
	//
	// oldRefreshHash 是这次要消费的会话当前摘要，used.TokenHash 是这次要记下的
	// 旧摘要。正常刷新两者相同，只写一条记录；宽限期内的重试里 used.TokenHash
	// 是客户端提交的更早摘要，与当前摘要不同，两条记录都指向本次发出的新令牌。
	// 记录里“本次发出的令牌”由实现按 newAccessHash 与 newRefreshHash 填好，调用
	// 方不用设置，轮换后的会话与记录因此不会写成两对不同的令牌。
	RotateSessionAndRecord(ctx context.Context, id, oldRefreshHash, newAccessHash, newRefreshHash string, accessExpires, refreshExpires time.Time, used RefreshUsed) error
	// UsedRefresh 返回已经轮换掉的刷新令牌摘要；没有记录时返回 ErrNotFound。
	UsedRefresh(ctx context.Context, tokenHash string) (RefreshUsed, error)
	DeleteSession(ctx context.Context, id string) error
	DeleteUserSessions(ctx context.Context, userID string) error

	// CreateKey 保存一把模型代理密钥，同时核对每个账号的有效密钥上限：达到
	// maxActive 把时返回 ErrKeyLimit。计数与写入在同一个事务或同一把锁里完成，
	// 并发签发不会各自按旧计数通过。
	CreateKey(ctx context.Context, key APIKey, keyHash string, maxActive int) error
	// KeysByUser 按创建时间倒序列出账号的全部密钥，包括已经撤销的。
	KeysByUser(ctx context.Context, userID string) ([]APIKey, error)
	// KeyByHash 按摘要找一把仍然有效的密钥；不存在或已经撤销时返回 ErrNotFound。
	// 返回的行里 ContactVerified 与访问令牌同一口径。
	KeyByHash(ctx context.Context, keyHash string) (APIKey, error)
	// RevokeKey 撤销当前账号名下的一把密钥。不存在、已经撤销或属于别的账号时
	// 返回 ErrNotFound，调用方据此回 404。
	RevokeKey(ctx context.Context, userID, id string) error
	// RevokeAllKeys 撤销账号名下所有仍然有效的密钥，返回撤销的条数。手动“撤销
	// 全部”与重设密码都用它，已经撤销的行保持不变。
	RevokeAllKeys(ctx context.Context, userID string) (int64, error)
	// TouchKey 把最近使用时间推进到 now；实现按十分钟粒度条件写入，大部分请求
	// 不会真的更新这一行。
	TouchKey(ctx context.Context, id string) error
	// PruneRevokedKeys 删除 revokedBefore 之前撤销的密钥行，返回删除的行数。已
	// 撤销的行只用于列表回看，超过保留期之后删掉，表不会随反复签发与撤销变长。
	PruneRevokedKeys(ctx context.Context, revokedBefore time.Time) (int64, error)
	// PruneExpired 删除刷新令牌已过期的会话与已过期的验证码；仍在有效期内的
	// 行不受影响。过期数据留在库里不影响正确性，清理只控制表的大小。
	PruneExpired(ctx context.Context, now, usedBefore time.Time) error
	// PruneUnverified 删除 before 之前创建、且没有任何一种已验证登录方式的账号，
	// 返回删除的账号数。账号的登录方式、会话、验证码与重放记录一并删除，与
	// schema 的 ON DELETE CASCADE 一致；保留期内注册的账号与已确认的账号不受影响。
	PruneUnverified(ctx context.Context, before time.Time) (int64, error)

	// ResetPassword 在一个事务里用掉验证码、换密码、确认那种登录方式并删除该
	// 账号的全部会话，四步要么一起成功，要么都不发生。验证码要同时匹配用途、
	// 登录方式、摘要且未过期才算用掉，否则返回 ErrInvalidCode。
	ResetPassword(ctx context.Context, reset PasswordReset) error

	// PutCode replaces the active code for one login identity and purpose.
	PutCode(ctx context.Context, c Code) error
	// Code returns ErrNotFound when no code is active.
	Code(ctx context.Context, purpose, kind, identifier string) (Code, error)
	// IncrementCodeAttempts adds one failed attempt and returns the new count.
	IncrementCodeAttempts(ctx context.Context, purpose, kind, identifier string) (int, error)
	DeleteCode(ctx context.Context, purpose, kind, identifier string) error
}

// MemoryStore is a Store kept in process memory.
type MemoryStore struct {
	mu           sync.Mutex
	users        map[string]User
	identities   map[string]Identity
	byKey        map[string]string // kind + "\x00" + identifier → identity id
	sessions     map[string]Session
	codes        map[string]Code
	codeAttempts map[string]int // 验证码摘要之外的输错次数，键与 codes 相同
	refreshUsed  map[string]RefreshUsed
	apiKeys      map[string]APIKey
	keyHashes    map[string]string // 密钥摘要 → 密钥编号
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{
		users:        map[string]User{},
		identities:   map[string]Identity{},
		byKey:        map[string]string{},
		sessions:     map[string]Session{},
		codes:        map[string]Code{},
		codeAttempts: map[string]int{},
		refreshUsed:  map[string]RefreshUsed{},
		apiKeys:      map[string]APIKey{},
		keyHashes:    map[string]string{},
	}
}

func codeKey(purpose, kind, identifier string) string {
	return purpose + "\x00" + kind + "\x00" + identifier
}

func identityKey(kind, identifier string) string { return kind + "\x00" + identifier }

// CreateAccount 写入账号与它的第一种登录方式；登录方式已经存在时账号也不落地，
// 与 PostgreSQL 实现里一个事务回滚的语义一致。
func (m *MemoryStore) CreateAccount(_ context.Context, u User, ident Identity) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.users[u.ID]; ok {
		return errors.New("auth: account id already used")
	}
	if _, ok := m.byKey[identityKey(ident.Kind, ident.Identifier)]; ok {
		return ErrIdentifierTaken
	}
	m.users[u.ID] = u
	m.identities[ident.ID] = ident
	m.byKey[identityKey(ident.Kind, ident.Identifier)] = ident.ID
	return nil
}

func (m *MemoryStore) UserByID(_ context.Context, id string) (User, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	u, ok := m.users[id]
	if !ok {
		return User{}, ErrNotFound
	}
	return u, nil
}

func (m *MemoryStore) UserByIdentifier(_ context.Context, kind, identifier string) (User, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	ident, ok := m.identities[m.byKey[identityKey(kind, identifier)]]
	if !ok {
		return User{}, ErrNotFound
	}
	u, ok := m.users[ident.UserID]
	if !ok {
		return User{}, ErrNotFound
	}
	return u, nil
}

func (m *MemoryStore) Identities(_ context.Context, userID string) ([]Identity, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.users[userID]; !ok {
		return nil, ErrNotFound
	}
	return m.identitiesLocked(userID), nil
}

// ListAccounts 在内存里按同一口径过滤、排序与分页；查询词先转小写，邮箱在写入
// 时已经规范化，账号编号本身区分大小写，但管理后台的搜索按不区分大小写处理，
// 与 PostgreSQL 的 lower 比较保持一致。
func (m *MemoryStore) ListAccounts(_ context.Context, query string, limit, offset int) ([]AccountRecord, int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	query = strings.ToLower(strings.TrimSpace(query))
	matched := make([]User, 0, len(m.users))
	for _, u := range m.users {
		if query != "" && !strings.Contains(strings.ToLower(u.ID), query) {
			byIdentifier := false
			for _, ident := range m.identities {
				if ident.UserID == u.ID && strings.Contains(strings.ToLower(ident.Identifier), query) {
					byIdentifier = true
					break
				}
			}
			if !byIdentifier {
				continue
			}
		}
		matched = append(matched, u)
	}
	sort.Slice(matched, func(i, j int) bool {
		if matched[i].CreatedAt.Equal(matched[j].CreatedAt) {
			return matched[i].ID < matched[j].ID
		}
		return matched[i].CreatedAt.After(matched[j].CreatedAt)
	})
	total := len(matched)
	if offset >= total {
		return []AccountRecord{}, total, nil
	}
	end := min(offset+limit, total)
	page := make([]AccountRecord, 0, end-offset)
	for _, u := range matched[offset:end] {
		page = append(page, AccountRecord{User: u, Identities: m.identitiesLocked(u.ID)})
	}
	return page, total, nil
}

// identitiesLocked 按创建顺序取一个账号的登录方式；调用方必须持有 m.mu。
func (m *MemoryStore) identitiesLocked(userID string) []Identity {
	list := make([]Identity, 0, len(m.identities))
	for _, ident := range m.identities {
		if ident.UserID == userID {
			list = append(list, ident)
		}
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].CreatedAt.Equal(list[j].CreatedAt) {
			return list[i].ID < list[j].ID
		}
		return list[i].CreatedAt.Before(list[j].CreatedAt)
	})
	return list
}

func (m *MemoryStore) Identity(_ context.Context, userID, identityID string) (Identity, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	ident, ok := m.identities[identityID]
	if !ok || ident.UserID != userID {
		return Identity{}, ErrNotFound
	}
	return ident, nil
}

func (m *MemoryStore) IdentityByIdentifier(_ context.Context, kind, identifier string) (Identity, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	ident, ok := m.identities[m.byKey[identityKey(kind, identifier)]]
	if !ok {
		return Identity{}, ErrNotFound
	}
	return ident, nil
}

func (m *MemoryStore) SetIdentityVerified(_ context.Context, userID, identityID string, at time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	ident, ok := m.identities[identityID]
	if !ok || ident.UserID != userID {
		return ErrNotFound
	}
	if ident.VerifiedAt.IsZero() {
		ident.VerifiedAt = at
	}
	m.identities[identityID] = ident
	return nil
}

// DeleteUser 删除账号及其登录方式、会话，与 schema.sql 的 ON DELETE CASCADE 一致。
func (m *MemoryStore) DeleteUser(_ context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.deleteUserLocked(id) {
		return ErrNotFound
	}
	return nil
}

// deleteUserLocked 删除账号及其登录方式、会话、验证码与重放记录，与 schema.sql
// 的 ON DELETE CASCADE 一致。账号不存在时返回 false。调用方已持有锁。
func (m *MemoryStore) deleteUserLocked(id string) bool {
	if _, ok := m.users[id]; !ok {
		return false
	}
	delete(m.users, id)
	for identityID, ident := range m.identities {
		if ident.UserID != id {
			continue
		}
		delete(m.identities, identityID)
		delete(m.byKey, identityKey(ident.Kind, ident.Identifier))
	}
	for sid, s := range m.sessions {
		if s.UserID == id {
			delete(m.sessions, sid)
		}
	}
	for keyID, key := range m.apiKeys {
		if key.UserID != id {
			continue
		}
		delete(m.apiKeys, keyID)
		for hash, owned := range m.keyHashes {
			if owned == keyID {
				delete(m.keyHashes, hash)
			}
		}
	}
	for key, c := range m.codes {
		if c.UserID == id {
			delete(m.codes, key)
			delete(m.codeAttempts, key)
		}
	}
	m.purgeUsedLocked(func(u RefreshUsed) bool { return u.UserID == id })
	return true
}

func (m *MemoryStore) DeleteUserSessions(_ context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for sid, s := range m.sessions {
		if s.UserID == userID {
			delete(m.sessions, sid)
		}
	}
	m.purgeUsedLocked(func(u RefreshUsed) bool { return u.UserID == userID })
	return nil
}

func (m *MemoryStore) CreateKey(_ context.Context, key APIKey, keyHash string, maxActive int) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	var active int
	for _, existing := range m.apiKeys {
		if existing.UserID == key.UserID && !existing.Revoked {
			active++
		}
	}
	if active >= maxActive {
		return ErrKeyLimit
	}
	m.apiKeys[key.ID] = key
	m.keyHashes[keyHash] = key.ID
	return nil
}

func (m *MemoryStore) KeysByUser(_ context.Context, userID string) ([]APIKey, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	keys := make([]APIKey, 0, len(m.apiKeys))
	for _, key := range m.apiKeys {
		if key.UserID == userID {
			keys = append(keys, key)
		}
	}
	sort.Slice(keys, func(i, j int) bool {
		if !keys[i].CreatedAt.Equal(keys[j].CreatedAt) {
			return keys[i].CreatedAt.After(keys[j].CreatedAt)
		}
		return keys[i].ID > keys[j].ID
	})
	return keys, nil
}

func (m *MemoryStore) KeyByHash(_ context.Context, keyHash string) (APIKey, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	id, ok := m.keyHashes[keyHash]
	if !ok {
		return APIKey{}, ErrNotFound
	}
	key, ok := m.apiKeys[id]
	if !ok || key.Revoked {
		return APIKey{}, ErrNotFound
	}
	for _, ident := range m.identities {
		if ident.UserID == key.UserID && !ident.VerifiedAt.IsZero() {
			key.ContactVerified = true
			break
		}
	}
	return key, nil
}

func (m *MemoryStore) RevokeKey(_ context.Context, userID, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	key, ok := m.apiKeys[id]
	if !ok || key.UserID != userID || key.Revoked {
		return ErrNotFound
	}
	key.Revoked = true
	key.RevokedAt = time.Now()
	m.apiKeys[id] = key
	return nil
}

func (m *MemoryStore) RevokeAllKeys(_ context.Context, userID string) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.revokeKeysLocked(userID), nil
}

// revokeKeysLocked 撤销账号名下仍然有效的密钥并返回条数，调用方已持有锁。
func (m *MemoryStore) revokeKeysLocked(userID string) int64 {
	var revoked int64
	revokedAt := time.Now()
	for id, key := range m.apiKeys {
		if key.UserID != userID || key.Revoked {
			continue
		}
		key.Revoked = true
		key.RevokedAt = revokedAt
		m.apiKeys[id] = key
		revoked++
	}
	return revoked
}

// PruneRevokedKeys 删除 revokedBefore 之前撤销的密钥行，摘要索引一并清掉。
func (m *MemoryStore) PruneRevokedKeys(_ context.Context, revokedBefore time.Time) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var removed int64
	for id, key := range m.apiKeys {
		if !key.Revoked || !key.RevokedAt.Before(revokedBefore) {
			continue
		}
		delete(m.apiKeys, id)
		for hash, owned := range m.keyHashes {
			if owned == id {
				delete(m.keyHashes, hash)
			}
		}
		removed++
	}
	return removed, nil
}

func (m *MemoryStore) TouchKey(_ context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	key, ok := m.apiKeys[id]
	if !ok {
		return ErrNotFound
	}
	if !key.LastUsedAt.IsZero() && time.Since(key.LastUsedAt) < 10*time.Minute {
		return nil
	}
	key.LastUsedAt = time.Now()
	m.apiKeys[id] = key
	return nil
}

// ResetPassword 在同一把锁里用完验证码、换密码、确认那种登录方式、删会话，
// 四步要么都成要么都不成。
func (m *MemoryStore) ResetPassword(_ context.Context, reset PasswordReset) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := codeKey(reset.Purpose, reset.Kind, reset.Identifier)
	c, ok := m.codes[key]
	if !ok || c.CodeHash != reset.ExpectedHash || !reset.Now.Before(c.ExpiresAt) {
		return ErrInvalidCode
	}
	u, ok := m.users[reset.UserID]
	if !ok {
		return ErrNotFound
	}
	delete(m.codes, key)
	delete(m.codeAttempts, key)
	u.PasswordHash = reset.NewPasswordHash
	m.users[reset.UserID] = u
	if ident, ok := m.identities[reset.IdentityID]; ok && ident.UserID == reset.UserID {
		if ident.VerifiedAt.IsZero() {
			ident.VerifiedAt = reset.Now
		}
		m.identities[reset.IdentityID] = ident
	}
	for sid, s := range m.sessions {
		if s.UserID == reset.UserID {
			delete(m.sessions, sid)
		}
	}
	m.purgeUsedLocked(func(u RefreshUsed) bool { return u.UserID == reset.UserID })
	// 重设密码通常意味着账号可能已经泄露，密钥随之全部撤销，与手动“撤销全部”
	// 同一做法（ADR-0063）。
	m.revokeKeysLocked(reset.UserID)
	return nil
}

func (m *MemoryStore) PutCode(_ context.Context, c Code) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := codeKey(c.Purpose, c.Kind, c.Identifier)
	m.codes[key] = c
	// 重新发送覆盖同一枚验证码时输错次数归零，与 SQL 里 ON CONFLICT 的
	// attempts = 0 一致。
	m.codeAttempts[key] = 0
	return nil
}

func (m *MemoryStore) Code(_ context.Context, purpose, kind, identifier string) (Code, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.codes[codeKey(purpose, kind, identifier)]
	if !ok {
		return Code{}, ErrNotFound
	}
	return c, nil
}

func (m *MemoryStore) IncrementCodeAttempts(_ context.Context, purpose, kind, identifier string) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := codeKey(purpose, kind, identifier)
	if _, ok := m.codes[key]; !ok {
		return 0, ErrNotFound
	}
	m.codeAttempts[key]++
	return m.codeAttempts[key], nil
}

func (m *MemoryStore) DeleteCode(_ context.Context, purpose, kind, identifier string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := codeKey(purpose, kind, identifier)
	delete(m.codes, key)
	delete(m.codeAttempts, key)
	return nil
}

// CreateSession 先核对密码摘要，再按上限删掉最旧的会话并插入新会话，三步在同一
// 把锁内完成：同一个账号的并发登录不会把会话数推过上限，登录核对密码之后密码被
// 重设时这次登录也不会留下会话。
func (m *MemoryStore) CreateSession(_ context.Context, s Session, maxPerUser int, expectedPasswordHash string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if expectedPasswordHash != "" && m.users[s.UserID].PasswordHash != expectedPasswordHash {
		return ErrInvalidCredentials
	}
	if maxPerUser < 1 {
		maxPerUser = 1
	}
	m.trimSessionsLocked(s.UserID, maxPerUser-1)
	m.sessions[s.ID] = s
	return nil
}

// trimSessionsLocked 保留账号最新的 keep 条会话，删掉更旧的。调用方已持有锁。
func (m *MemoryStore) trimSessionsLocked(userID string, keep int) {
	if keep < 0 {
		keep = 0
	}
	type owned struct {
		id      string
		created time.Time
	}
	list := make([]owned, 0, len(m.sessions))
	for id, s := range m.sessions {
		if s.UserID == userID {
			list = append(list, owned{id: id, created: s.CreatedAt})
		}
	}
	if len(list) <= keep {
		return
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].created.Equal(list[j].created) {
			return list[i].id < list[j].id
		}
		return list[i].created.Before(list[j].created)
	})
	for _, o := range list[:len(list)-keep] {
		delete(m.sessions, o.id)
	}
}

// PruneExpired 删除刷新令牌已经过期的会话与过期的验证码。
func (m *MemoryStore) PruneExpired(_ context.Context, now, usedBefore time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	gone := map[string]bool{}
	for id, s := range m.sessions {
		if !now.Before(s.RefreshExpires) {
			delete(m.sessions, id)
			gone[id] = true
		}
	}
	m.purgeUsedLocked(func(u RefreshUsed) bool { return gone[u.SessionID] || u.RotatedAt.Before(usedBefore) })
	for key, c := range m.codes {
		if !now.Before(c.ExpiresAt) {
			delete(m.codes, key)
			delete(m.codeAttempts, key)
		}
	}
	return nil
}

// PruneUnverified 删除 before 之前创建、且没有任何一种已验证登录方式的账号及其
// 登录方式、会话、验证码与重放记录，返回删除的账号数。
func (m *MemoryStore) PruneUnverified(_ context.Context, before time.Time) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var removed int64
	for id, u := range m.users {
		if !u.CreatedAt.Before(before) || m.hasVerifiedIdentityLocked(id) {
			continue
		}
		if m.deleteUserLocked(id) {
			removed++
		}
	}
	return removed, nil
}

// hasVerifiedIdentityLocked 判断账号是否至少有一种登录方式已经确认。调用方已
// 持有锁。
func (m *MemoryStore) hasVerifiedIdentityLocked(userID string) bool {
	for _, ident := range m.identities {
		if ident.UserID == userID && !ident.VerifiedAt.IsZero() {
			return true
		}
	}
	return false
}

func (m *MemoryStore) findSession(match func(Session) bool) (Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, s := range m.sessions {
		if match(s) {
			s.ContactVerified = m.hasVerifiedIdentityLocked(s.UserID)
			return s, nil
		}
	}
	return Session{}, ErrNotFound
}

func (m *MemoryStore) SessionByAccessHash(_ context.Context, hash string) (Session, error) {
	return m.findSession(func(s Session) bool { return s.AccessHash == hash })
}

func (m *MemoryStore) SessionByRefreshHash(_ context.Context, hash string) (Session, error) {
	return m.findSession(func(s Session) bool { return s.RefreshHash == hash })
}

// RotateSessionAndRecord 在同一把锁里做 CAS 并写重放记录：轮换成功时会话与记录
// 一起可见，CAS 失败或写记录前出错时一条都不落地，因此不存在“令牌换了但重放
// 记录缺失”的窗口。
func (m *MemoryStore) RotateSessionAndRecord(_ context.Context, id, oldRefreshHash, newAccessHash, newRefreshHash string, accessExpires, refreshExpires time.Time, used RefreshUsed) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.sessions[id]
	if !ok || s.RefreshHash != oldRefreshHash {
		return ErrInvalidToken
	}
	s.AccessHash = newAccessHash
	s.RefreshHash = newRefreshHash
	s.AccessExpires = accessExpires
	s.RefreshExpires = refreshExpires
	m.sessions[id] = s
	// 记录里的“本次发出的令牌”由这里按刚写入会话的摘要填好，调用方不用设置。
	used.ReplacedRefreshHash = newRefreshHash
	m.recordRefreshUsedLocked(used)
	if used.TokenHash != oldRefreshHash {
		// 宽限期内的重试：客户端提交的更早摘要与这次消费的当前摘要不是同一个，
		// 两条都要指向本次发出的新令牌，连续重试才都按重试处理。
		other := used
		other.TokenHash = oldRefreshHash
		m.recordRefreshUsedLocked(other)
	}
	return nil
}

func (m *MemoryStore) UsedRefresh(_ context.Context, tokenHash string) (RefreshUsed, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	u, ok := m.refreshUsed[tokenHash]
	if !ok {
		return RefreshUsed{}, ErrNotFound
	}
	return u, nil
}

// recordRefreshUsedLocked 保存一条重放记录。同一个摘要重复写入时只更新“本次
// 发出的令牌”，宽限截止时间与 request_id 保留第一次的值，重试因此不会延长宽限
// 期，连续重试也仍然能按记录里的最新摘要再轮换。调用方已持有锁。
func (m *MemoryStore) recordRefreshUsedLocked(u RefreshUsed) {
	if old, ok := m.refreshUsed[u.TokenHash]; ok {
		old.RotatedAt = u.RotatedAt
		old.ReplacedRefreshHash = u.ReplacedRefreshHash
		m.refreshUsed[u.TokenHash] = old
		return
	}
	m.refreshUsed[u.TokenHash] = u
}

// purgeUsedLocked 删掉不再需要判断重放的旧令牌记录，与 PostgreSQL 实现里
// session_refresh_used 的 ON DELETE CASCADE 一致。调用方已持有锁。
func (m *MemoryStore) purgeUsedLocked(match func(RefreshUsed) bool) {
	for hash, u := range m.refreshUsed {
		if match(u) {
			delete(m.refreshUsed, hash)
		}
	}
}

func (m *MemoryStore) DeleteSession(_ context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.sessions[id]; !ok {
		return ErrNotFound
	}
	delete(m.sessions, id)
	m.purgeUsedLocked(func(u RefreshUsed) bool { return u.SessionID == id })
	return nil
}
