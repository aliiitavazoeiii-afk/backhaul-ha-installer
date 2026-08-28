package shield

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"fmt"
	"log"
	"net"
	"sync"
)

const (
	veilPublicPort   = "8443"
	veilLoopbackAddr = "127.0.0.1:9443"
	veilMaxDatagram  = 64 * 1024
)

type veilKey struct {
	id  string
	c2s cipher.AEAD
	s2c cipher.AEAD
}

func newVeilAEAD(token, direction string) (cipher.AEAD, error) {
	sum := sha256.Sum256([]byte("dragon-shield-veil-v1|" + direction + "|" + token))
	block, err := aes.NewCipher(sum[:])
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func newVeilKey(id, token string) (veilKey, error) {
	c2s, err := newVeilAEAD(token, "client-to-server")
	if err != nil {
		return veilKey{}, err
	}
	s2c, err := newVeilAEAD(token, "server-to-client")
	if err != nil {
		return veilKey{}, err
	}
	return veilKey{id: id, c2s: c2s, s2c: s2c}, nil
}

func veilSeal(aead cipher.AEAD, plain []byte) ([]byte, error) {
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	out := make([]byte, 0, len(nonce)+len(plain)+aead.Overhead())
	out = append(out, nonce...)
	out = aead.Seal(out, nonce, plain, nil)
	return out, nil
}

func veilOpen(aead cipher.AEAD, packet []byte) ([]byte, error) {
	ns := aead.NonceSize()
	if len(packet) < ns+aead.Overhead() {
		return nil, fmt.Errorf("veil packet too short")
	}
	return aead.Open(nil, packet[:ns], packet[ns:], nil)
}

func startClientVeil(cfg ClientConfig) (func(), error) {
	key, err := newVeilKey(cfg.ClientID, cfg.Token)
	if err != nil {
		return nil, fmt.Errorf("create veil key: %w", err)
	}
	localAddr, err := net.ResolveUDPAddr("udp4", veilLoopbackAddr)
	if err != nil {
		return nil, err
	}
	localConn, err := net.ListenUDP("udp4", localAddr)
	if err != nil {
		return nil, fmt.Errorf("listen veil loopback %s: %w", veilLoopbackAddr, err)
	}
	remoteAddr, err := net.ResolveUDPAddr("udp4", transportServer(cfg.Server))
	if err != nil {
		_ = localConn.Close()
		return nil, fmt.Errorf("resolve veil server: %w", err)
	}
	outerConn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		_ = localConn.Close()
		return nil, fmt.Errorf("open veil outer socket: %w", err)
	}

	var closeOnce sync.Once
	closeFn := func() {
		closeOnce.Do(func() {
			_ = localConn.Close()
			_ = outerConn.Close()
		})
	}

	var peerMu sync.RWMutex
	var localPeer *net.UDPAddr

	go func() {
		buf := make([]byte, veilMaxDatagram)
		for {
			n, peer, err := localConn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			p := *peer
			p.IP = append(net.IP(nil), peer.IP...)
			peerMu.Lock()
			localPeer = &p
			peerMu.Unlock()

			sealed, err := veilSeal(key.c2s, buf[:n])
			if err != nil {
				log.Printf("dragon-shield: veil client seal error: %v", err)
				continue
			}
			if _, err := outerConn.WriteToUDP(sealed, remoteAddr); err != nil {
				log.Printf("dragon-shield: veil client send error: %v", err)
			}
		}
	}()

	go func() {
		buf := make([]byte, veilMaxDatagram)
		for {
			n, from, err := outerConn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			if from.Port != remoteAddr.Port || !from.IP.Equal(remoteAddr.IP) {
				continue
			}
			plain, err := veilOpen(key.s2c, buf[:n])
			if err != nil {
				continue
			}
			peerMu.RLock()
			peer := localPeer
			peerMu.RUnlock()
			if peer == nil {
				continue
			}
			if _, err := localConn.WriteToUDP(plain, peer); err != nil {
				log.Printf("dragon-shield: veil client loopback send error: %v", err)
			}
		}
	}()

	log.Printf("dragon-shield: encrypted UDP veil client %s -> %s", veilLoopbackAddr, remoteAddr)
	return closeFn, nil
}

type veilServerSession struct {
	remote *net.UDPAddr
	inner  *net.UDPConn
	reply  cipher.AEAD
	id     string
}

func startServerVeil(cfg ServerConfig) (func(), error) {
	keys := make([]veilKey, 0, len(cfg.Clients))
	for _, cl := range cfg.Clients {
		k, err := newVeilKey(cl.ID, cl.Token)
		if err != nil {
			return nil, fmt.Errorf("create veil key for %s: %w", cl.ID, err)
		}
		keys = append(keys, k)
	}
	if len(keys) == 0 {
		return nil, fmt.Errorf("encrypted UDP veil requires at least one client")
	}

	publicAddr, err := net.ResolveUDPAddr("udp4", ":"+veilPublicPort)
	if err != nil {
		return nil, err
	}
	outerConn, err := net.ListenUDP("udp4", publicAddr)
	if err != nil {
		return nil, fmt.Errorf("listen veil public UDP/%s: %w", veilPublicPort, err)
	}
	innerTarget, err := net.ResolveUDPAddr("udp4", veilLoopbackAddr)
	if err != nil {
		_ = outerConn.Close()
		return nil, err
	}

	var mu sync.Mutex
	sessions := make(map[string]*veilServerSession)
	var closeOnce sync.Once
	closeFn := func() {
		closeOnce.Do(func() {
			_ = outerConn.Close()
			mu.Lock()
			for _, s := range sessions {
				_ = s.inner.Close()
			}
			sessions = map[string]*veilServerSession{}
			mu.Unlock()
		})
	}

	startReplyLoop := func(s *veilServerSession) {
		go func() {
			buf := make([]byte, veilMaxDatagram)
			for {
				n, err := s.inner.Read(buf)
				if err != nil {
					return
				}
				sealed, err := veilSeal(s.reply, buf[:n])
				if err != nil {
					continue
				}
				if _, err := outerConn.WriteToUDP(sealed, s.remote); err != nil {
					return
				}
			}
		}()
	}

	go func() {
		buf := make([]byte, veilMaxDatagram)
		for {
			n, remote, err := outerConn.ReadFromUDP(buf)
			if err != nil {
				return
			}

			var plain []byte
			var matched *veilKey
			for i := range keys {
				p, openErr := veilOpen(keys[i].c2s, buf[:n])
				if openErr == nil {
					plain = p
					matched = &keys[i]
					break
				}
			}
			if matched == nil {
				continue
			}

			remoteCopy := *remote
			remoteCopy.IP = append(net.IP(nil), remote.IP...)
			mapKey := remote.String()

			mu.Lock()
			s := sessions[mapKey]
			if s == nil || s.id != matched.id {
				if s != nil {
					_ = s.inner.Close()
				}
				inner, dialErr := net.DialUDP("udp4", nil, innerTarget)
				if dialErr != nil {
					mu.Unlock()
					log.Printf("dragon-shield: veil server loopback dial error: %v", dialErr)
					continue
				}
				s = &veilServerSession{remote: &remoteCopy, inner: inner, reply: matched.s2c, id: matched.id}
				sessions[mapKey] = s
				startReplyLoop(s)
				log.Printf("dragon-shield: encrypted UDP veil session %s from %s", matched.id, remote)
			}
			mu.Unlock()

			if _, err := s.inner.Write(plain); err != nil {
				log.Printf("dragon-shield: veil server loopback send error: %v", err)
			}
		}
	}()

	log.Printf("dragon-shield: encrypted UDP veil server listening on :%s/udp -> %s", veilPublicPort, veilLoopbackAddr)
	return closeFn, nil
}
