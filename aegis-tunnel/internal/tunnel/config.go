package tunnel

import "time"

type ListenerConfig struct {
	Listen   string `json:"listen"`
	TargetID uint16 `json:"target_id"`
}

type TargetConfig struct {
	ID      uint16 `json:"id"`
	Address string `json:"address"`
}

type ServerConfig struct {
	Bind             string           `json:"bind"`
	Token            string           `json:"token"`
	PathPrefix       string           `json:"path_prefix"`
	KeepAliveSeconds int              `json:"keepalive_seconds"`
	Listeners        []ListenerConfig `json:"listeners"`
}

type ClientConfig struct {
	RemoteAddr       string         `json:"remote_addr"`
	EdgeIP           string         `json:"edge_ip"`
	Scheme           string         `json:"scheme"`
	TLSServerName    string         `json:"tls_server_name"`
	TLSSkipVerify    bool           `json:"tls_skip_verify"`
	Token            string         `json:"token"`
	PathPrefix       string         `json:"path_prefix"`
	Origin           string         `json:"origin"`
	Pool             int            `json:"pool"`
	DialTimeoutSec   int            `json:"dial_timeout_seconds"`
	KeepAliveSeconds int            `json:"keepalive_seconds"`
	Targets          []TargetConfig `json:"targets"`
}

func (c ServerConfig) keepAlive() time.Duration {
	if c.KeepAliveSeconds <= 0 {
		return 25 * time.Second
	}
	return time.Duration(c.KeepAliveSeconds) * time.Second
}
func (c ClientConfig) keepAlive() time.Duration {
	if c.KeepAliveSeconds <= 0 {
		return 25 * time.Second
	}
	return time.Duration(c.KeepAliveSeconds) * time.Second
}
func (c ClientConfig) dialTimeout() time.Duration {
	if c.DialTimeoutSec <= 0 {
		return 10 * time.Second
	}
	return time.Duration(c.DialTimeoutSec) * time.Second
}
