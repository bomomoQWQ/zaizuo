package relay

import (
	"bufio"
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

// net.Pipe makes the upgrade response block until the controlled socket closes.
// This covers the interval after HTTP hijacking but before a WS client exists.
type notifyingConn struct {
	net.Conn
	started chan struct{}
	once    sync.Once
}

func (c *notifyingConn) Write(b []byte) (int, error) {
	c.once.Do(func() { close(c.started) })
	return c.Conn.Write(b)
}

type hijackWriter struct {
	headers http.Header
	conn    net.Conn
}

func (w *hijackWriter) Header() http.Header       { return w.headers }
func (w *hijackWriter) Write([]byte) (int, error) { return 0, nil }
func (w *hijackWriter) WriteHeader(int)           {}
func (w *hijackWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return w.conn, bufio.NewReadWriter(bufio.NewReader(w.conn), bufio.NewWriter(w.conn)), nil
}

func TestShutdownClosesPendingHijackedUpgrade(t *testing.T) {
	s, err := New(DefaultConfig(testToken))
	if err != nil {
		t.Fatal(err)
	}
	serverSide, peerSide := net.Pipe()
	defer peerSide.Close()
	conn := &notifyingConn{Conn: serverSide, started: make(chan struct{})}
	defer conn.Close()
	writer := &hijackWriter{headers: make(http.Header), conn: conn}
	req := httptest.NewRequest(http.MethodGet, "http://127.0.0.1/v1/ws", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Upgrade", "websocket")
	req.Header.Set("Sec-WebSocket-Version", "13")
	req.Header.Set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
	done := make(chan struct{})
	go func() { defer close(done); s.ServeHTTP(writer, req) }()
	awaitSignal(t, conn.started)
	ctx, cancel := context.WithTimeout(context.Background(), testWait)
	defer cancel()
	if err := s.Shutdown(ctx); err != nil {
		t.Fatal(err)
	}
	awaitSignal(t, done)
	s.mu.Lock()
	pending, admitted := len(s.upgrades), s.admitted
	s.mu.Unlock()
	if pending != 0 || admitted != 0 {
		t.Fatalf("pending upgrade leaked: %d %d", pending, admitted)
	}
}
