package tunnel

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"
)

const authSkew = 75 * time.Second

type replayCache struct {
	mu sync.Mutex
	m  map[string]time.Time
}

func newReplayCache() *replayCache { return &replayCache{m: make(map[string]time.Time)} }

func (r *replayCache) accept(nonce string, now time.Time) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	cutoff := now.Add(-2 * authSkew)
	for k, t := range r.m {
		if t.Before(cutoff) {
			delete(r.m, k)
		}
	}
	if _, ok := r.m[nonce]; ok {
		return false
	}
	r.m[nonce] = now
	return true
}

func randomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func randomPadding(minLen, maxLen int) (string, error) {
	if minLen < 0 || maxLen < minLen {
		return "", errors.New("invalid padding bounds")
	}
	span := maxLen - minLen + 1
	n := minLen
	if span > 1 {
		var b [2]byte
		if _, err := rand.Read(b[:]); err != nil {
			return "", err
		}
		v := int(b[0])<<8 | int(b[1])
		n += v % span
	}
	rawLen := (n*3 + 3) / 4
	b := make([]byte, rawLen)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	s := base64.RawURLEncoding.EncodeToString(b)
	if len(s) > n {
		s = s[:n]
	}
	for len(s) < n {
		s += "A"
	}
	return s, nil
}

func authSignature(token, unix, nonce, path string) string {
	mac := hmac.New(sha256.New, []byte(token))
	_, _ = mac.Write([]byte(unix))
	_, _ = mac.Write([]byte("\n"))
	_, _ = mac.Write([]byte(nonce))
	_, _ = mac.Write([]byte("\n"))
	_, _ = mac.Write([]byte(path))
	return hex.EncodeToString(mac.Sum(nil))
}

func verifyAuth(token, unix, nonce, path, sig string, now time.Time, replay *replayCache) error {
	if len(nonce) != 32 || len(sig) != 64 {
		return errors.New("bad auth shape")
	}
	ts, err := strconv.ParseInt(unix, 10, 64)
	if err != nil {
		return errors.New("bad timestamp")
	}
	dt := now.Sub(time.Unix(ts, 0))
	if dt < 0 {
		dt = -dt
	}
	if dt > authSkew {
		return errors.New("stale timestamp")
	}
	want := authSignature(token, unix, nonce, path)
	if len(want) != len(sig) || subtle.ConstantTimeCompare([]byte(strings.ToLower(want)), []byte(strings.ToLower(sig))) != 1 {
		return errors.New("bad signature")
	}
	if replay != nil && !replay.accept(nonce, now) {
		return errors.New("replay")
	}
	return nil
}

func newAuth(token, path string) (unix, nonce, sig string, err error) {
	nonce, err = randomHex(16)
	if err != nil {
		return "", "", "", fmt.Errorf("nonce: %w", err)
	}
	unix = strconv.FormatInt(time.Now().Unix(), 10)
	sig = authSignature(token, unix, nonce, path)
	return
}
