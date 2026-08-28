package shield

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"strings"
)

const DefaultMTU = 1080

type CommonTunConfig struct {
	TunName string `json:"tun_name"`
	TunCIDR string `json:"tun_cidr"`
	MTU     int    `json:"mtu"`
}

type ServerClient struct {
	ID    string `json:"id"`
	IP    string `json:"ip"`
	Token string `json:"token"`
}

type ServerConfig struct {
	Role             string         `json:"role"`
	Listen           string         `json:"listen"`
	PublicDomain     string         `json:"public_domain"`
	TLSCert          string         `json:"tls_cert"`
	TLSKey           string         `json:"tls_key"`
	TunName          string         `json:"tun_name"`
	TunCIDR          string         `json:"tun_cidr"`
	MTU              int            `json:"mtu"`
	WebTransportPath string         `json:"webtransport_path"`
	WebSocketPath    string         `json:"websocket_path"`
	Clients          []ServerClient `json:"clients"`
}

type ClientConfig struct {
	Role             string `json:"role"`
	Server           string `json:"server"`
	ServerName       string `json:"server_name"`
	TunName          string `json:"tun_name"`
	TunCIDR          string `json:"tun_cidr"`
	MTU              int    `json:"mtu"`
	ServerTunIP      string `json:"server_tun_ip"`
	ClientID         string `json:"client_id"`
	Token            string `json:"token"`
	WebTransportPath string `json:"webtransport_path"`
	WebSocketPath    string `json:"websocket_path"`
	Mode             string `json:"mode"`
}

func LoadServerConfig(path string) (ServerConfig, error) {
	var c ServerConfig
	if err := loadJSON(path, &c); err != nil {
		return c, err
	}
	if c.Listen == "" {
		c.Listen = ":443"
	}
	if c.MTU == 0 {
		c.MTU = DefaultMTU
	}
	if c.TunName == "" || c.TunCIDR == "" || c.TLSCert == "" || c.TLSKey == "" {
		return c, errors.New("server config requires tun_name, tun_cidr, tls_cert and tls_key")
	}
	if !validSecretPath(c.WebTransportPath) || !validSecretPath(c.WebSocketPath) {
		return c, errors.New("invalid secret transport path")
	}
	serverIP, _, err := net.ParseCIDR(c.TunCIDR)
	if err != nil || serverIP.To4() == nil {
		return c, fmt.Errorf("invalid server tun_cidr %q", c.TunCIDR)
	}
	seenID := map[string]bool{}
	seenIP := map[string]bool{}
	for i := range c.Clients {
		cl := c.Clients[i]
		ip := net.ParseIP(cl.IP)
		if cl.ID == "" || len(cl.Token) < 32 || ip == nil || ip.To4() == nil {
			return c, fmt.Errorf("invalid client entry %d", i)
		}
		if seenID[cl.ID] || seenIP[ip.String()] {
			return c, fmt.Errorf("duplicate client id or ip at entry %d", i)
		}
		seenID[cl.ID] = true
		seenIP[ip.String()] = true
	}
	return c, nil
}

func LoadClientConfig(path string) (ClientConfig, error) {
	var c ClientConfig
	if err := loadJSON(path, &c); err != nil {
		return c, err
	}
	if c.MTU == 0 {
		c.MTU = DefaultMTU
	}
	if c.Mode == "" {
		c.Mode = "auto"
	}
	if c.TunName == "" || c.TunCIDR == "" || c.Server == "" || c.ServerName == "" || c.ServerTunIP == "" || c.ClientID == "" || len(c.Token) < 32 {
		return c, errors.New("client config is missing required fields")
	}
	if !validSecretPath(c.WebTransportPath) || !validSecretPath(c.WebSocketPath) {
		return c, errors.New("invalid secret transport path")
	}
	clientIP, _, err := net.ParseCIDR(c.TunCIDR)
	if err != nil || clientIP.To4() == nil {
		return c, fmt.Errorf("invalid client tun_cidr %q", c.TunCIDR)
	}
	if ip := net.ParseIP(c.ServerTunIP); ip == nil || ip.To4() == nil {
		return c, fmt.Errorf("invalid server_tun_ip %q", c.ServerTunIP)
	}
	switch strings.ToLower(c.Mode) {
	case "auto", "webtransport", "websocket":
	default:
		return c, fmt.Errorf("unsupported mode %q", c.Mode)
	}
	return c, nil
}

func LoadCommonTunConfig(path string) (CommonTunConfig, error) {
	var c CommonTunConfig
	if err := loadJSON(path, &c); err != nil {
		return c, err
	}
	if c.MTU == 0 {
		c.MTU = DefaultMTU
	}
	if c.TunName == "" || c.TunCIDR == "" {
		return c, errors.New("tun_name and tun_cidr are required")
	}
	return c, nil
}

func loadJSON(path string, dst any) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(b, dst); err != nil {
		return fmt.Errorf("parse %s: %w", path, err)
	}
	return nil
}

func validSecretPath(p string) bool {
	return strings.HasPrefix(p, "/") && len(p) >= 12 && !strings.ContainsAny(p, " \t\r\n?#")
}
