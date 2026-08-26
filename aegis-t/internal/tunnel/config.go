package tunnel

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"
)

type ServerConfig struct {
	CarrierListen   string `json:"carrier_listen"`
	UserListen      string `json:"user_listen"`
	ReadinessListen string `json:"readiness_listen"`
	CertFile        string `json:"cert_file"`
	KeyFile         string `json:"key_file"`
	Token           string `json:"token"`
	PathPrefix      string `json:"path_prefix"`
	Host            string `json:"host"`
	MinReady        int    `json:"min_ready"`
	MaxIdle         int    `json:"max_idle"`
	AcquireTimeout  int    `json:"acquire_timeout_ms"`
	CarrierTTL      int    `json:"carrier_ttl_seconds"`
}

type ClientConfig struct {
	RemoteAddr     string `json:"remote_addr"`
	EdgeIP         string `json:"edge_ip"`
	TLSServerName  string `json:"tls_server_name"`
	Token          string `json:"token"`
	PathPrefix     string `json:"path_prefix"`
	Pool           int    `json:"pool"`
	Target         string `json:"target"`
	HealthTarget   string `json:"health_target"`
	HealthInterval int    `json:"health_interval_seconds"`
	DialTimeout    int    `json:"dial_timeout_seconds"`
	PaddingMin     int    `json:"padding_min"`
	PaddingMax     int    `json:"padding_max"`
}

func LoadServerConfig(path string) (ServerConfig, error) {
	var c ServerConfig
	b, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	if err := json.Unmarshal(b, &c); err != nil {
		return c, err
	}
	if c.CarrierListen == "" {
		c.CarrierListen = "127.0.0.1:9443"
	}
	if c.UserListen == "" {
		c.UserListen = "127.0.0.1:10443"
	}
	if c.ReadinessListen == "" {
		c.ReadinessListen = "127.0.0.1:10444"
	}
	if c.MinReady <= 0 {
		c.MinReady = 2
	}
	if c.MaxIdle <= 0 {
		c.MaxIdle = 256
	}
	if c.MaxIdle < c.MinReady {
		return c, errors.New("max_idle must be >= min_ready")
	}
	if c.AcquireTimeout <= 0 {
		c.AcquireTimeout = 1500
	}
	if c.CarrierTTL <= 0 {
		c.CarrierTTL = 180
	}
	if c.CertFile == "" || c.KeyFile == "" {
		return c, errors.New("cert_file/key_file required")
	}
	if len(c.Token) < 32 {
		return c, errors.New("token must be at least 32 bytes")
	}
	if !validPrefix(c.PathPrefix) {
		return c, errors.New("path_prefix must start with / and be at least 12 chars")
	}
	if c.Host == "" {
		return c, errors.New("host required")
	}
	return c, nil
}

func LoadClientConfig(path string) (ClientConfig, error) {
	var c ClientConfig
	b, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	if err := json.Unmarshal(b, &c); err != nil {
		return c, err
	}
	if c.RemoteAddr == "" {
		return c, errors.New("remote_addr required")
	}
	if c.TLSServerName == "" {
		return c, errors.New("tls_server_name required")
	}
	if len(c.Token) < 32 {
		return c, errors.New("token must be at least 32 bytes")
	}
	if !validPrefix(c.PathPrefix) {
		return c, errors.New("path_prefix must start with / and be at least 12 chars")
	}
	if c.Pool <= 0 {
		c.Pool = 32
	}
	if c.Pool > 128 {
		return c, fmt.Errorf("pool too large: %d", c.Pool)
	}
	if c.Target == "" {
		c.Target = "127.0.0.1:443"
	}
	if c.HealthTarget == "" {
		c.HealthTarget = c.Target
	}
	if c.HealthInterval <= 0 {
		c.HealthInterval = 2
	}
	if c.DialTimeout <= 0 {
		c.DialTimeout = 8
	}
	if c.PaddingMin <= 0 {
		c.PaddingMin = 96
	}
	if c.PaddingMax <= 0 {
		c.PaddingMax = 640
	}
	if c.PaddingMax < c.PaddingMin || c.PaddingMax > 4096 {
		return c, errors.New("invalid padding range")
	}
	return c, nil
}

func validPrefix(s string) bool {
	return strings.HasPrefix(s, "/") && len(s) >= 12 && !strings.ContainsAny(s, " \t\r\n")
}

func (c ServerConfig) acquireTimeout() time.Duration {
	return time.Duration(c.AcquireTimeout) * time.Millisecond
}

func (c ServerConfig) carrierTTL() time.Duration {
	return time.Duration(c.CarrierTTL) * time.Second
}

func (c ClientConfig) healthInterval() time.Duration {
	return time.Duration(c.HealthInterval) * time.Second
}

func (c ClientConfig) dialTimeout() time.Duration {
	return time.Duration(c.DialTimeout) * time.Second
}
