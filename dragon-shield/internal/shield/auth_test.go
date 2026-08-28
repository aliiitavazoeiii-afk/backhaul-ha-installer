package shield

import (
	"testing"
	"time"
)

func TestAuthRoundTripAndReplay(t *testing.T) {
	client := ServerClient{ID: "iran-1", IP: "10.203.0.2", Token: "0123456789abcdef0123456789abcdef0123456789abcdef"}
	clients := map[string]ServerClient{client.ID: client}
	path := "/assets/0123456789abcdef01234567"
	h, err := newAuthHeaders(client.ID, client.Token, path)
	if err != nil {
		t.Fatal(err)
	}
	r := newReplayCache()
	got, err := verifyAuthHeaders(h, path, clients, r, time.Now())
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if got.ID != client.ID {
		t.Fatalf("got id %q", got.ID)
	}
	if _, err := verifyAuthHeaders(h, path, clients, r, time.Now()); err == nil {
		t.Fatal("expected replay rejection")
	}
}

func TestAuthWrongTokenFails(t *testing.T) {
	client := ServerClient{ID: "iran-1", IP: "10.203.0.2", Token: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
	clients := map[string]ServerClient{client.ID: client}
	path := "/assets/0123456789abcdef01234567"
	h, err := newAuthHeaders(client.ID, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := verifyAuthHeaders(h, path, clients, newReplayCache(), time.Now()); err == nil {
		t.Fatal("expected signature failure")
	}
}
