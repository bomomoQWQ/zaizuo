package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"

	relay "example.com/zaizuo/relay-go"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Getenv, os.Stderr); err != nil {
		// Errors are deliberately static; no arguments, tokens, paths, request
		// contents or peer addresses are included in diagnostics.
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// loadToken reads an explicitly selected file only; there is no token command
// line flag. One final LF/CRLF is allowed for editor/secret-file convenience.
// It does not trim any other whitespace, and an invalid file does not fall back
// to the environment. No value or file path is included in returned errors.
func loadToken(tokenFile string, getenv func(string) string) (string, error) {
	token := getenv("ZAIZUO_RELAY_TOKEN")
	if tokenFile != "" {
		f, err := os.Open(tokenFile)
		if err != nil {
			return "", fmt.Errorf("cannot read token file")
		}
		defer f.Close()
		info, err := f.Stat()
		if err != nil || !info.Mode().IsRegular() || info.Size() > 258 {
			return "", fmt.Errorf("invalid token file")
		}
		b, err := io.ReadAll(io.LimitReader(f, 259))
		if err != nil || len(b) > 258 {
			return "", fmt.Errorf("cannot read token file")
		}
		token = strings.TrimSuffix(string(b), "\n")
		if len(b) > 0 && b[len(b)-1] == '\n' {
			token = strings.TrimSuffix(token, "\r")
		}
	}
	if err := relay.ValidateToken(token); err != nil {
		return "", err
	}
	return token, nil
}

func run(ctx context.Context, args []string, getenv func(string) string, output io.Writer) error {
	cfg := relay.DefaultConfig("")
	flags := flag.NewFlagSet("relay", flag.ContinueOnError)
	// flag's default error formatting can echo an invalid value. Discard it and
	// return one fixed error; explicit -h uses the same safe usage text below.
	flags.SetOutput(io.Discard)
	listen := flags.String("listen", "127.0.0.1:8787", "HTTP listen address; use TLS reverse proxy for cross-host access")
	tokenFile := flags.String("token-file", "", "read token from this file instead of ZAIZUO_RELAY_TOKEN")
	flags.IntVar(&cfg.MaxConnections, "max-connections", cfg.MaxConnections, "maximum admitted connections")
	flags.IntVar(&cfg.MaxTopics, "max-topics", cfg.MaxTopics, "maximum subscriptions per connection")
	flags.Int64Var(&cfg.MaxMessageBytes, "max-message-bytes", cfg.MaxMessageBytes, "maximum UTF-8 WebSocket message bytes")
	flags.IntVar(&cfg.MaxPayloadBytes, "max-payload-bytes", cfg.MaxPayloadBytes, "maximum decoded payload bytes")
	flags.IntVar(&cfg.QueueCapacity, "queue-capacity", cfg.QueueCapacity, "outbound messages per connection")
	flags.IntVar(&cfg.MaxRequests, "max-requests", cfg.MaxRequests, "requests per connection per fixed window")
	flags.DurationVar(&cfg.RateWindow, "rate-window", cfg.RateWindow, "fixed request-count window")
	flags.DurationVar(&cfg.PingInterval, "ping-interval", cfg.PingInterval, "ping interval; pong grace is twice this duration")
	flags.DurationVar(&cfg.WriteTimeout, "write-timeout", cfg.WriteTimeout, "write and close deadline")
	if err := flags.Parse(args); err != nil {
		if err == flag.ErrHelp {
			fmt.Fprintln(output, "在座 Go 哑中继：令牌来自 ZAIZUO_RELAY_TOKEN 或只读 -token-file；默认仅本机 HTTP。")
			flags.SetOutput(output)
			flags.PrintDefaults()
			return nil
		}
		return fmt.Errorf("invalid command line flags; use -h for usage")
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected positional arguments; use -h for usage")
	}
	token, err := loadToken(*tokenFile, getenv)
	if err != nil {
		return err
	}
	cfg.Token = token
	handler, err := relay.New(cfg)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		return fmt.Errorf("cannot open relay listener")
	}
	defer listener.Close()
	httpServer := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: cfg.WriteTimeout,
		IdleTimeout:       2 * cfg.PingInterval,
		MaxHeaderBytes:    16 << 10,
		ErrorLog:          log.New(io.Discard, "", 0), // never echo request data in net/http diagnostics
	}
	serveResult := make(chan error, 1)
	go func() { serveResult <- httpServer.Serve(listener) }()
	fmt.Fprintln(output, "在座哑中继已启动；不记录正文、不持久化，跨主机请使用 TLS/WSS。")
	var serveErr error
	select {
	case <-ctx.Done():
	case serveErr = <-serveResult:
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*cfg.WriteTimeout)
	defer cancel()
	// HTTP shutdown by itself leaves hijacked sockets open. Shut down both
	// concurrently within the same bounded grace period.
	httpDone := make(chan error, 1)
	go func() { httpDone <- httpServer.Shutdown(shutdownCtx) }()
	relayErr := handler.Shutdown(shutdownCtx)
	httpErr := <-httpDone
	if relayErr != nil || httpErr != nil {
		_ = httpServer.Close()
		return fmt.Errorf("relay shutdown grace expired")
	}
	if serveErr != nil && serveErr != http.ErrServerClosed {
		return fmt.Errorf("relay HTTP server stopped unexpectedly")
	}
	return nil
}
