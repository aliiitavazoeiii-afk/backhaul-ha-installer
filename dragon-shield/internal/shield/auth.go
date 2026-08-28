package shield

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
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

func newReplayCache() *replayCache {
	return &replayCache{m: make(map[string]time.Time)}
}

func (r *replayCache) accept(key string, now time.Time) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	cutoff := now.Add(-2 * authSkew)
	for k, t := range r.m {
		if t.Before(cutoff) {
			delete(r.m, k)
		}
	}
	if _, ok := r.m[key]; ok {
		return false
	}
	r.m[key] = now
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
		n += (int(b[0])<<8 | int(b[1])) % span
	}
	raw := make([]byte, (n*3+3)/4)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	s := base64.RawURLEncoding.EncodeToString(raw)
	if len(s) > n {
		s = s[:n]
	}
	for len(s) < n {
		s += "A"
	}
	return s, nil
}

func authSignature(token, clientID, unix, nonce, path string) string {
	mac := hmac.New(sha256.New, []byte(token))
	_, _ = mac.Write([]byte(clientID))
	_, _ = mac.Write([]byte("\n"))
	_, _ = mac.Write([]byte(unix))
	_, _ = mac.Write([]byte("\n"))
	_, _ = mac.Write([]byte(nonce))
	_, _ = mac.Write([]byte("\n"))
	_, _ = mac.Write([]byte(path))
	return hex.EncodeToString(mac.Sum(nil))
}

func newAuthHeaders(clientID, token, path string) (http.Header, error) {
	nonce, err := randomHex(16)
	if err != nil {
		return nil, fmt.Errorf("nonce: %w", err)
	}
	padding, err := randomPadding(64, 224)
	if err != nil {
		return nil, fmt.Errorf("padding: %w", err)
	}
	unix := strconv.FormatInt(time.Now().Unix(), 10)
	h := make(http.Header)
	h.Set("X-Client-ID", clientID)
	h.Set("X-Request-Time", unix)
	h.Set("X-Request-ID", nonce)
	h.Set("X-Request-Signature", authSignature(token, clientID, unix, nonce, path))
	h.Set("X-Client-Data", padding)
	return h, nil
}

func verifyAuthHeaders(h http.Header, path string, clients map[string]ServerClient, replay *replayCache, now time.Time) (ServerClient, error) {
	clientID := strings.TrimSpace(h.Get("X-Client-ID"))
	unix := strings.TrimSpace(h.Get("X-Request-Time"))
	nonce := strings.TrimSpace(h.Get("X-Request-ID"))
	sig := strings.TrimSpace(h.Get("X-Request-Signature"))
	client, ok := clients[clientID]
	if !ok || clientID == "" {
		return ServerClient{}, errors.New("unknown client")
	}
	if len(nonce) != 32 || len(sig) != 64 {
		return ServerClient{}, errors.New("bad auth shape")
	}
	ts, err := strconv.ParseInt(unix, 10, 64)
	if err != nil {
		return ServerClient{}, errors.New("bad timestamp")
	}
	dt := now.Sub(time.Unix(ts, 0))
	if dt < 0 {
		dt = -dt
	}
	if dt > authSkew {
		return ServerClient{}, errors.New("stale timestamp")
	}
	want := authSignature(client.Token, clientID, unix, nonce, path)
	if len(want) != len(sig) || subtle.ConstantTimeCompare([]byte(strings.ToLower(want)), []byte(strings.ToLower(sig))) != 1 {
		return ServerClient{}, errors.New("bad signature")
	}
	if replay != nil && !replay.accept(clientID+":"+nonce, now) {
		return ServerClient{}, errors.New("replay")
	}
	return client, nil
}
