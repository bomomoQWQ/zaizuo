package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const cliTestToken = "cli-test-only-token-never-used-for-production-1234"

func TestLoadToken(t *testing.T) {
	getenv := func(key string) string {
		if key != "ZAIZUO_RELAY_TOKEN" {
			t.Fatalf("unexpected env %s", key)
		}
		return cliTestToken
	}
	if token, err := loadToken("", getenv); err != nil || token != cliTestToken {
		t.Fatalf("env token: %v", err)
	}
	for _, suffix := range []string{"", "\n", "\r\n"} {
		path := filepath.Join(t.TempDir(), "token")
		if err := os.WriteFile(path, []byte(cliTestToken+suffix), 0600); err != nil {
			t.Fatal(err)
		}
		token, err := loadToken(path, func(string) string { return strings.Repeat("x", 32) })
		if err != nil || token != cliTestToken {
			t.Fatalf("token file with %q: %v", suffix, err)
		}
		data, err := os.ReadFile(path)
		if err != nil || string(data) != cliTestToken+suffix {
			t.Fatal("token file modified")
		}
	}
	for _, value := range []string{"", cliTestToken + " ", cliTestToken + "\n\n", strings.Repeat("x", 259)} {
		path := filepath.Join(t.TempDir(), "token")
		if err := os.WriteFile(path, []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := loadToken(path, getenv); err == nil {
			t.Fatal("invalid token file fell back to env")
		}
	}
	if _, err := loadToken(filepath.Join(t.TempDir(), "missing-secret-path"), getenv); err == nil || strings.Contains(err.Error(), "missing-secret-path") {
		t.Fatal("missing token file not handled safely")
	}
	if _, err := loadToken("", func(string) string { return "" }); err == nil {
		t.Fatal("empty token accepted")
	}
}

func TestCLIRejectsMissingTokenAndInvalidConfigBeforeListen(t *testing.T) {
	var output bytes.Buffer
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := run(ctx, nil, func(string) string { return "" }, &output); err == nil {
		t.Fatal("missing token started service")
	}
	if output.Len() != 0 {
		t.Fatal("missing-token startup emitted success")
	}
	if err := run(ctx, []string{"-max-connections=0"}, func(string) string { return cliTestToken }, &output); err == nil {
		t.Fatal("invalid limits accepted")
	}
	if err := run(ctx, []string{"-queue-capacity=SECRET_VALUE"}, func(string) string { return cliTestToken }, &output); err == nil || strings.Contains(err.Error(), "SECRET_VALUE") || strings.Contains(output.String(), "SECRET_VALUE") {
		t.Fatal("invalid option echoed")
	}
	if err := run(ctx, []string{"-token", cliTestToken}, func(string) string { return "" }, &output); err == nil || strings.Contains(err.Error(), cliTestToken) {
		t.Fatal("token command-line flag accepted/echoed")
	}
}

func TestCLIHelpDefaultsAndShutdown(t *testing.T) {
	var output bytes.Buffer
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := run(ctx, []string{"-h"}, func(string) string { return "" }, &output); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "127.0.0.1:8787") || strings.Contains(output.String(), cliTestToken) {
		t.Fatal("unsafe/default-less help")
	}
	output.Reset()
	if err := run(ctx, []string{"-listen=127.0.0.1:0"}, func(string) string { return cliTestToken }, &output); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(output.String(), cliTestToken) {
		t.Fatal("token logged")
	}
}
