package emulator

import (
	"crypto/rand"
	"encoding/hex"
	"net"
	"net/http"
	"sync"
	"time"
)

// Upstream (jetkvm/kvm ratelimit.go): 5 wrong passwords per client IP lock the
// IP out for 15 minutes (rising on repeat offences). Successful logins are
// never rate-limited and clear the counter.
const (
	loginMaxAttempts  = 5
	loginLockoutDelay = 15 * time.Minute
)

type loginLimiter struct {
	mu      sync.Mutex
	entries map[string]*loginEntry
}

type loginEntry struct {
	failures    int
	lockedUntil time.Time
}

func newLoginLimiter() *loginLimiter {
	return &loginLimiter{entries: map[string]*loginEntry{}}
}

// allowed reports whether ip may attempt a login, and if not, how many whole
// seconds remain until it may.
func (l *loginLimiter) allowed(ip string, now time.Time) (bool, int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	entry := l.entries[ip]
	if entry == nil || entry.lockedUntil.IsZero() || !now.Before(entry.lockedUntil) {
		return true, 0
	}
	return false, int(entry.lockedUntil.Sub(now).Seconds()) + 1
}

func (l *loginLimiter) recordFailure(ip string, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	entry := l.entries[ip]
	if entry == nil {
		entry = &loginEntry{}
		l.entries[ip] = entry
	}
	entry.failures++
	if entry.failures >= loginMaxAttempts {
		entry.lockedUntil = now.Add(loginLockoutDelay)
	}
}

func (l *loginLimiter) recordSuccess(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.entries, ip)
}

// newAuthToken mirrors upstream, which mints a fresh UUID on every successful
// login and thereby invalidates every previously issued cookie.
func newAuthToken() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
