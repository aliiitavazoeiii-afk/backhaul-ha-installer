package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/aliiitavazoeiii-afk/backhaul-ha-installer/aegis-t/internal/tunnel"
)

const version = "1.0.0"

func main() {
	role := flag.String("role", "", "server|client")
	config := flag.String("config", "", "path to JSON config")
	showVersion := flag.Bool("version", false, "show version")
	flag.Parse()

	if *showVersion {
		fmt.Println(version)
		return
	}
	if *role == "" || *config == "" {
		flag.Usage()
		os.Exit(2)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	switch *role {
	case "server":
		cfg, err := tunnel.LoadServerConfig(*config)
		if err != nil {
			log.Fatal(err)
		}
		if err := tunnel.NewServer(cfg).Run(ctx); err != nil {
			log.Fatal(err)
		}
	case "client":
		cfg, err := tunnel.LoadClientConfig(*config)
		if err != nil {
			log.Fatal(err)
		}
		if err := tunnel.NewClient(cfg).Run(ctx); err != nil {
			log.Fatal(err)
		}
	default:
		log.Fatalf("unknown role %q", *role)
	}
}
