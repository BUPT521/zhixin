package httpx

import (
	"context"
	"crypto/rand"
	"log/slog"
	"net/http"
	"regexp"
	"time"
)

type ctxKey int

const requestIDKey ctxKey = iota

// RequestIDFrom returns the request id stored by RequestID, or "".
func RequestIDFrom(ctx context.Context) string {
	id, _ := ctx.Value(requestIDKey).(string)
	return id
}

var validRequestID = regexp.MustCompile(`^[A-Za-z0-9_-]{8,64}$`)

// RequestID accepts a well-formed X-Request-Id from the client or makes one,
// stores it in the context and echoes it back.
func RequestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.Header.Get("X-Request-Id")
		if !validRequestID.MatchString(id) {
			// crypto/rand.Text 生成 26 个 base32 字符，满足上面的形状校验。
			id = rand.Text()
		}
		w.Header().Set("X-Request-Id", id)
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), requestIDKey, id)))
	})
}

// statusRecorder remembers the status code and the matched route, and keeps
// http.Flusher working, which the streaming model proxy depends on.
type statusRecorder struct {
	http.ResponseWriter
	status  int
	bytes   int64
	pattern string
}

// SetPattern records the route matched by net/http. RecordPattern runs inside
// the generated wrapper, where r.Pattern is already set on the request.
func (s *statusRecorder) SetPattern(pattern string) { s.pattern = pattern }

// RecordPattern passes the matched route to the access log. The generated
// wrapper runs after net/http has matched a route, so r.Pattern is already set;
// the recorder is behind SecurityHeaders' cacheGuard, which forwards SetPattern
// to the statusRecorder (S19).
func RecordPattern(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if rec, ok := w.(interface{ SetPattern(string) }); ok {
			rec.SetPattern(r.Pattern)
		}
		next.ServeHTTP(w, r)
	})
}

func (s *statusRecorder) WriteHeader(code int) {
	if s.status == 0 {
		s.status = code
	}
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	n, err := s.ResponseWriter.Write(b)
	s.bytes += int64(n)
	return n, err
}

func (s *statusRecorder) Flush() {
	if f, ok := s.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (s *statusRecorder) Unwrap() http.ResponseWriter { return s.ResponseWriter }

// AccessLog logs one line per request. It records the route pattern rather
// than the raw path and never logs bodies, query strings or headers, so
// learning content and tokens stay out of the logs (ADR-0008).
func AccessLog(log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			rec := &statusRecorder{ResponseWriter: w}
			next.ServeHTTP(rec, r)
			pattern := rec.pattern
			if pattern == "" {
				pattern = r.Pattern
			}
			if pattern == "" {
				pattern = "unmatched"
			}
			log.LogAttrs(r.Context(), slog.LevelInfo, "request",
				slog.String("request_id", RequestIDFrom(r.Context())),
				slog.String("route", pattern),
				slog.Int("status", rec.status),
				slog.Int64("bytes", rec.bytes),
				slog.Duration("duration", time.Since(start)),
			)
		})
	}
}

// Recover turns a panic into a 500 problem and logs the panic value type only.
func Recover(log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				if v := recover(); v != nil {
					if v == http.ErrAbortHandler {
						panic(v)
					}
					log.Error("panic", slog.String("request_id", RequestIDFrom(r.Context())), slog.String("route", r.Pattern))
					WriteProblem(w, r, http.StatusInternalServerError, CodeInternal, "")
				}
			}()
			next.ServeHTTP(w, r)
		})
	}
}

// Chain applies middleware so that the first one listed runs outermost.
func Chain(h http.Handler, mw ...func(http.Handler) http.Handler) http.Handler {
	for i := len(mw) - 1; i >= 0; i-- {
		h = mw[i](h)
	}
	return h
}
