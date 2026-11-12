package relay

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// gatedTransport blocks exactly at application writes under channel control;
// unlike TCP-buffer-filling tests it does not depend on OS socket-buffer sizes,
// sleeps, scheduling guesses or sending gigabytes to simulate one slow peer.
type gatedTransport struct {
	gate      <-chan struct{}
	started   chan struct{}
	writes    chan []byte
	closes    chan int
	closed    chan struct{}
	closeOnce sync.Once
	writeErr  error
}

func newGatedTransport(gate <-chan struct{}) *gatedTransport {
	return &gatedTransport{gate: gate, started: make(chan struct{}, 32), writes: make(chan []byte, 32), closes: make(chan int, 4), closed: make(chan struct{})}
}
func (g *gatedTransport) ReadMessage() (int, []byte, error) { <-g.closed; return 0, nil, io.EOF }
func (g *gatedTransport) WriteMessage(_ int, data []byte) error {
	g.started <- struct{}{}
	if g.gate != nil {
		select {
		case <-g.gate:
		case <-g.closed:
			return io.ErrClosedPipe
		}
	}
	if g.writeErr != nil {
		return g.writeErr
	}
	g.writes <- append([]byte(nil), data...)
	return nil
}
func (g *gatedTransport) WriteControl(kind int, data []byte, _ time.Time) error {
	if kind == websocket.CloseMessage && len(data) >= 2 {
		g.closes <- int(binary.BigEndian.Uint16(data[:2]))
	}
	return nil
}
func (g *gatedTransport) SetReadLimit(int64)                      {}
func (g *gatedTransport) SetReadDeadline(time.Time) error         { return nil }
func (g *gatedTransport) SetWriteDeadline(time.Time) error        { return nil }
func (g *gatedTransport) SetPongHandler(func(string) error)       {}
func (g *gatedTransport) SetPingHandler(func(string) error)       {}
func (g *gatedTransport) SetCloseHandler(func(int, string) error) {}
func (g *gatedTransport) Close() error                            { g.closeOnce.Do(func() { close(g.closed) }); return nil }

func awaitSignal(t *testing.T, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(testWait):
		t.Fatal("channel coordination deadline exceeded")
	}
}
func awaitWritten(t *testing.T, g *gatedTransport) response {
	t.Helper()
	select {
	case data := <-g.writes:
		var r response
		if err := json.Unmarshal(data, &r); err != nil {
			t.Fatal(err)
		}
		return r
	case <-time.After(testWait):
		t.Fatal("writer did not produce a response")
		return response{}
	}
}
func awaitCloseCode(t *testing.T, g *gatedTransport, code int) {
	t.Helper()
	select {
	case got := <-g.closes:
		if got != code {
			t.Fatalf("close=%d want %d", got, code)
		}
	case <-time.After(testWait):
		t.Fatal("missing close control")
	}
}

func TestSlowConnectionQueueIsolation(t *testing.T) {
	cfg := DefaultConfig(testToken)
	cfg.QueueCapacity = 1
	cfg.PingInterval = time.Hour
	s, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	gate := make(chan struct{})
	slowNet := newGatedTransport(gate)
	fastNet := newGatedTransport(nil)
	publisherNet := newGatedTransport(nil)
	slow, fast, publisher := newClient(s, slowNet), newClient(s, fastNet), newClient(s, publisherNet)
	for _, c := range []*client{slow, fast, publisher} {
		if !s.register(c) {
			t.Fatal("register")
		}
		s.mu.Lock()
		c.topics[topicA] = struct{}{}
		if s.topics[topicA] == nil {
			s.topics[topicA] = make(map[*client]struct{})
		}
		s.topics[topicA][c] = struct{}{}
		s.mu.Unlock()
		go c.writeLoop()
	}
	t.Cleanup(func() {
		for _, c := range []*client{slow, fast, publisher} {
			c.stop(websocket.CloseGoingAway, "test cleanup")
			_ = c.conn.Close()
		}
		for _, c := range []*client{slow, fast, publisher} {
			awaitSignal(t, c.writerDone)
		}
	})
	for i := 0; i < 3; i++ {
		s.handle(publisher, request{Op: "publish", RequestID: "p", Topic: topicA, Payload: "AQID"})
		if i == 0 {
			awaitSignal(t, slowNet.started)
		} // slow is now blocked in a write
		if r := awaitWritten(t, fastNet); r.Op != "event" {
			t.Fatal(r)
		}
		if r := awaitWritten(t, publisherNet); r.Op != "ok" {
			t.Fatal(r)
		}
	}
	// The third event filled the slow queue; healthy writes and publisher acks
	// above completed *before* its blocked write was released.
	if !slow.stopped.Load() {
		t.Fatal("full queue did not stop slow connection")
	}
	s.mu.Lock()
	_, stillSubscribed := s.topics[topicA][slow]
	s.mu.Unlock()
	if stillSubscribed {
		t.Fatal("slow peer remained subscribed")
	}
	close(gate)
	awaitCloseCode(t, slowNet, websocket.CloseTryAgainLater)
	awaitSignal(t, slow.writerDone)
	if slow.enqueue([]byte("discard")) {
		t.Fatal("closed client accepted new data")
	}
}

func TestWriteFailureUses1013(t *testing.T) {
	cfg := DefaultConfig(testToken)
	cfg.PingInterval = time.Hour
	s, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	g := newGatedTransport(nil)
	g.writeErr = errors.New("simulated write deadline")
	c := newClient(s, g)
	s.register(c)
	c.send(response{Op: "ready", Version: 1})
	go c.writeLoop()
	awaitCloseCode(t, g, websocket.CloseTryAgainLater)
	awaitSignal(t, c.writerDone)
	if !c.stopped.Load() {
		t.Fatal("failed writer remained active")
	}
}

func TestShutdownDeadlineForcesBlockedTransportClosed(t *testing.T) {
	cfg := DefaultConfig(testToken)
	cfg.PingInterval = time.Hour
	s, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	gate := make(chan struct{})
	g := newGatedTransport(gate)
	c := newClient(s, g)
	if !s.reserve() || !s.register(c) {
		t.Fatal("admission")
	}
	runDone := make(chan struct{})
	go func() { defer close(runDone); defer s.release(); c.run() }()
	awaitSignal(t, g.started)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := s.Shutdown(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v", err)
	}
	awaitSignal(t, runDone)
	s.mu.Lock()
	clients, admitted := len(s.clients), s.admitted
	s.mu.Unlock()
	if clients != 0 || admitted != 0 {
		t.Fatalf("shutdown leaked %d %d", clients, admitted)
	}
}
