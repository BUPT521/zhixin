package auth

import (
	"errors"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"sync"
	"time"

	"golang.org/x/time/rate"

	"github.com/BUPT521/zhixin/server/internal/httpx"
)

var errRefreshLimited = errors.New("auth: refresh rate limit reached")

const (
	rateMaxKeys = 16384
	rateIdle    = 15 * time.Minute
)

type rateKey struct {
	bucket *rate.Limiter
	usedAt time.Time
}

type rateBuckets struct {
	mu        sync.Mutex
	entries   map[string]rateKey
	limit     rate.Limit
	burst     int
	nextSweep time.Time
}

func newRateBuckets(interval time.Duration, burst int) *rateBuckets {
	return &rateBuckets{entries: make(map[string]rateKey), limit: rate.Every(interval), burst: burst}
}

func (r *rateBuckets) wait(key string, now time.Time) time.Duration {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !now.Before(r.nextSweep) {
		for k, entry := range r.entries {
			if now.Sub(entry.usedAt) >= rateIdle {
				delete(r.entries, k)
			}
		}
		r.nextSweep = now.Add(time.Minute)
	}
	entry, ok := r.entries[key]
	if !ok {
		if len(r.entries) >= rateMaxKeys {
			return time.Minute
		}
		entry.bucket = rate.NewLimiter(r.limit, r.burst)
	}
	entry.usedAt = now
	r.entries[key] = entry
	if entry.bucket.AllowN(now, 1) {
		return 0
	}
	shortage := 1 - entry.bucket.TokensAt(now)
	return max(time.Second, time.Duration(shortage/float64(r.limit)*float64(time.Second)))
}

type rateLimits struct {
	login          *rateBuckets
	register       *rateBuckets
	refreshAddress *rateBuckets
	refreshAccount *rateBuckets
	now            func() time.Time
}

func newRateLimits() rateLimits {
	return rateLimits{
		login:          newRateBuckets(6*time.Second, 10),
		register:       newRateBuckets(20*time.Second, 3),
		refreshAddress: newRateBuckets(2*time.Second, 30),
		refreshAccount: newRateBuckets(5*time.Second, 12),
		now:            time.Now,
	}
}

func sourceAddress(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if ip, err := netip.ParseAddr(host); err == nil {
		return ip.Unmap().WithZone("").String()
	}
	return ""
}

func allowRate(w http.ResponseWriter, r *http.Request, retry time.Duration) bool {
	if retry <= 0 {
		return true
	}
	seconds := (retry + time.Second - 1) / time.Second
	w.Header().Set("Retry-After", strconv.FormatInt(int64(seconds), 10))
	httpx.WriteProblem(w, r, http.StatusTooManyRequests, httpx.CodeRateLimited, "")
	return false
}
