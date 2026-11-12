package relay

import (
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// An unlimited fake sender proves byte bounding without actually sending large
// buffers or waiting for an OS timer. It records ordering/deadline synchronously.
type drainConn struct {
	net.Conn
	events       []string
	readDeadline time.Time
	bytes        int64
	halfErr      error
	deadlineErr  error
}

func (c *drainConn) SetReadDeadline(deadline time.Time) error {
	c.events = append(c.events, "deadline")
	c.readDeadline = deadline
	return c.deadlineErr
}
func (c *drainConn) CloseWrite() error {
	c.events = append(c.events, "half-close")
	return c.halfErr
}
func (c *drainConn) Read(b []byte) (int, error) {
	c.events = append(c.events, "read")
	c.bytes += int64(len(b))
	return len(b), nil
}

type drainingTransport struct {
	*gatedTransport
	raw             *drainConn
	controlDeadline time.Time
}

func (t *drainingTransport) UnderlyingConn() net.Conn { return t.raw }
func (t *drainingTransport) WriteControl(kind int, data []byte, deadline time.Time) error {
	t.raw.events = append(t.raw.events, "close-control")
	t.controlDeadline = deadline
	return t.gatedTransport.WriteControl(kind, data, deadline)
}

func TestOversizeCloseDrainsBoundedBytesAfter1009(t *testing.T) {
	s, err := New(DefaultConfig(testToken))
	if err != nil {
		t.Fatal(err)
	}
	for _, code := range []int{websocket.CloseMessageTooBig, websocket.CloseUnsupportedData, websocket.CloseTryAgainLater} {
		raw := &drainConn{}
		transport := &drainingTransport{gatedTransport: newGatedTransport(nil), raw: raw}
		c := newClient(s, transport)
		c.stop(code, "test")
		c.finishWriter()
		awaitCloseCode(t, transport.gatedTransport, code)
		if code == websocket.CloseMessageTooBig {
			if len(raw.events) < 4 || raw.events[0] != "close-control" || raw.events[1] != "deadline" || raw.events[2] != "half-close" || raw.events[3] != "read" {
				t.Fatalf("close ordering %v", raw.events)
			}
			if raw.bytes != maxCloseDrainBytes {
				t.Fatalf("discarded %d want exact cap %d", raw.bytes, maxCloseDrainBytes)
			}
			if raw.readDeadline.IsZero() || !raw.readDeadline.Equal(transport.controlDeadline) {
				t.Fatal("close and drain did not share one absolute deadline")
			}
		} else if raw.bytes != 0 || len(raw.events) != 1 {
			t.Fatalf("unrelated close %d drained rejected input", code)
		}
	}
}

func TestRejectedMessageDrainStopsOnDeadlineAndHalfCloseFailure(t *testing.T) {
	deadline := time.Now().Add(time.Second)
	for _, raw := range []*drainConn{{deadlineErr: io.ErrClosedPipe}, {halfErr: io.ErrClosedPipe}} {
		drainRejectedMessage(raw, deadline)
		if raw.bytes != 0 {
			t.Fatal("read after setup failure")
		}
	}
	left, right := net.Pipe()
	defer left.Close()
	defer right.Close()
	// A past deadline deterministically proves blocked input does not wait.
	done := make(chan struct{})
	go func() { defer close(done); drainRejectedMessage(left, time.Now().Add(-time.Second)) }()
	awaitSignal(t, done)
}

func TestTrackedConnForwardsTCPHalfClose(t *testing.T) {
	raw := &drainConn{}
	tracked := &trackedConn{Conn: raw}
	if err := tracked.CloseWrite(); err != nil {
		t.Fatal(err)
	}
	if len(raw.events) != 1 || raw.events[0] != "half-close" {
		t.Fatal("lost TCP half-close through tracking wrapper")
	}
}

// This fake WS read-limit return proves the production path invokes bounded
// draining only after ReadMessage has returned, not alongside a WS reader.
type readLimitTransport struct {
	*drainingTransport
	returned chan struct{}
	once     sync.Once
}

func (t *readLimitTransport) ReadMessage() (int, []byte, error) {
	t.once.Do(func() { close(t.returned) })
	return 0, nil, websocket.ErrReadLimit
}
func TestReadLimitLifecycleCloses1009WithBoundedDrain(t *testing.T) {
	s, err := New(DefaultConfig(testToken))
	if err != nil {
		t.Fatal(err)
	}
	raw := &drainConn{}
	transport := &readLimitTransport{drainingTransport: &drainingTransport{gatedTransport: newGatedTransport(nil), raw: raw}, returned: make(chan struct{})}
	c := newClient(s, transport)
	if !s.register(c) {
		t.Fatal("register")
	}
	done := make(chan struct{})
	go func() { defer close(done); c.run() }()
	awaitSignal(t, done)
	awaitSignal(t, transport.returned)
	awaitCloseCode(t, transport.gatedTransport, websocket.CloseMessageTooBig)
	if raw.bytes != maxCloseDrainBytes {
		t.Fatal("read-limit path did not apply drain cap")
	}
}
