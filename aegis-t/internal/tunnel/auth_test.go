package tunnel

import (
	"testing"
	"time"
)

func TestAuthAndReplay(t *testing.T) {
	token := "0123456789abcdef0123456789abcdef"
	path := "/assets/abcdefghijkl/test"
	unix, nonce, sig, err := newAuth(token, path)
	if err != nil {
		t.Fatal(err)
	}
	r := newReplayCache()
	if err := verifyAuth(token, unix, nonce, path, sig, time.Now(), r); err != nil {
		t.Fatalf("verify: %v", err)
	}
	if err := verifyAuth(token, unix, nonce, path, sig, time.Now(), r); err == nil {
		t.Fatal("expected replay rejection")
	}
}

func TestBadSignature(t *testing.T) {
	token := "0123456789abcdef0123456789abcdef"
	path := "/assets/abcdefghijkl/test"
	unix, nonce, sig, err := newAuth(token, path)
	if err != nil {
		t.Fatal(err)
	}
	if sig[0] == '0' {
		sig = "1" + sig[1:]
	} else {
		sig = "0" + sig[1:]
	}
	if err := verifyAuth(token, unix, nonce, path, sig, time.Now(), nil); err == nil {
		t.Fatal("expected signature rejection")
	}
}
