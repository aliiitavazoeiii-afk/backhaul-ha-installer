package main

import (
	"flag"
	"fmt"
	"log"
	"os"

	"github.com/aliiitavazoeiii-afk/backhaul-ha-installer/dragon-shield/internal/shield"
)

const version = "1.0.0"

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "server":
		fs := flag.NewFlagSet("server", flag.ExitOnError)
		config := fs.String("config", "/etc/dragon-shield/server.json", "server config path")
		_ = fs.Parse(os.Args[2:])
		cfg, err := shield.LoadServerConfig(*config)
		fatalIf(err)
		fatalIf(shield.RunServer(cfg))
	case "client":
		fs := flag.NewFlagSet("client", flag.ExitOnError)
		config := fs.String("config", "/etc/dragon-shield/client.json", "client config path")
		_ = fs.Parse(os.Args[2:])
		cfg, err := shield.LoadClientConfig(*config)
		fatalIf(err)
		fatalIf(shield.RunClient(cfg))
	case "prepare-tun":
		fs := flag.NewFlagSet("prepare-tun", flag.ExitOnError)
		config := fs.String("config", "", "config path")
		_ = fs.Parse(os.Args[2:])
		if *config == "" {
			log.Fatal("-config is required")
		}
		cfg, err := shield.LoadCommonTunConfig(*config)
		fatalIf(err)
		fatalIf(shield.PrepareTun(cfg))
	case "version", "-version", "--version":
		fmt.Println(version)
	default:
		usage()
		os.Exit(2)
	}
}

func fatalIf(err error) {
	if err != nil {
		log.Fatal(err)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, "dragon-shield %s\n\n", version)
	fmt.Fprintln(os.Stderr, "Usage:")
	fmt.Fprintln(os.Stderr, "  dragon-shield server -config /etc/dragon-shield/server.json")
	fmt.Fprintln(os.Stderr, "  dragon-shield client -config /etc/dragon-shield/client.json")
	fmt.Fprintln(os.Stderr, "  dragon-shield prepare-tun -config /etc/dragon-shield/server.json")
	fmt.Fprintln(os.Stderr, "  dragon-shield version")
}
