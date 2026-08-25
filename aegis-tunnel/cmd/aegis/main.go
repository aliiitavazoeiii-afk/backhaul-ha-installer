package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/aliiitavazoeiii-afk/backhaul-ha-installer/aegis-tunnel/internal/tunnel"
)

const version = "0.2.0"

func main() {
	var role, cfg string
	var showVersion bool
	flag.StringVar(&role, "role", "", "server|client")
	flag.StringVar(&cfg, "config", "", "JSON config path")
	flag.BoolVar(&showVersion, "version", false, "show version")
	flag.Parse()
	if showVersion {
		fmt.Println(version)
		return
	}
	if role != "server" && role != "client" {
		fmt.Fprintln(os.Stderr, "-role must be server or client")
		os.Exit(2)
	}
	if cfg == "" {
		fmt.Fprintln(os.Stderr, "-config required")
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	var err error
	if role == "server" {
		var c tunnel.ServerConfig
		c, err = tunnel.LoadServerConfig(cfg)
		if err == nil {
			err = tunnel.NewServer(c).Run(ctx)
		}
	} else {
		var c tunnel.ClientConfig
		c, err = tunnel.LoadClientConfig(cfg)
		if err == nil {
			err = tunnel.NewClient(c).Run(ctx)
		}
	}
	if err != nil {
		log.Printf("fatal: %v", err)
		os.Exit(1)
	}
}
