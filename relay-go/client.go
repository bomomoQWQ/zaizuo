package relay

import (
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

// wsTransport is a narrow internal seam for deterministic queue/timeout tests.
// Production always uses gorilla/websocket; no WebSocket wire code is hand-written.
type wsTransport interface {
	ReadMessage() (int, []byte, error)
	WriteMessage(int, []byte) error
	WriteControl(int, []byte, time.Time) error
	SetReadLimit(int64)
	SetReadDeadline(time.Time) error
	SetWriteDeadline(time.Time) error
	SetPongHandler(func(string) error)
	SetPingHandler(func(string) error)
	SetCloseHandler(func(int, string) error)
	Close() error
}

type closeReason struct {
	code int
	text string
}

type client struct {
	server     *Server
	conn       wsTransport
	out        chan []byte
	done       chan struct{}
	writerDone chan struct{}
	stopOnce   sync.Once
	stopped    atomic.Bool
	reason     closeReason         // written before done closes, then read by writer
	topics     map[string]struct{} // only under server.mu
}

func newClient(s *Server, conn wsTransport) *client {
	return &client{
		server: s, conn: conn,
		out:  make(chan []byte, s.cfg.QueueCapacity),
		done: make(chan struct{}), writerDone: make(chan struct{}),
		topics: make(map[string]struct{}),
	}
}

func (c *client) stop(code int, text string) {
	c.stopOnce.Do(func() {
		c.stopped.Store(true)
		c.reason = closeReason{code: code, text: text}
		close(c.done)
		c.server.detach(c)
	})
}

func (c *client) enqueue(data []byte) bool {
	if c.stopped.Load() {
		return false
	}
	select {
	case <-c.done:
		return false
	case c.out <- data:
		return true
	default:
		c.stop(websocket.CloseTryAgainLater, "slow connection")
		return false
	}
}

func (c *client) send(r response) bool { return c.enqueue(encodeResponse(r)) }

func (c *client) run() {
	defer c.server.forget(c)
	cfg := c.server.cfg
	c.conn.SetReadLimit(cfg.MaxMessageBytes)
	_ = c.conn.SetReadDeadline(time.Now().Add(2 * cfg.PingInterval))
	c.conn.SetPongHandler(func(string) error {
		return c.conn.SetReadDeadline(time.Now().Add(2 * cfg.PingInterval))
	})
	// Gorilla allows WriteControl concurrently with other operations. Bound it
	// with the same write deadline and never reflect arbitrary ping bytes to logs.
	c.conn.SetPingHandler(func(data string) error {
		err := c.conn.WriteControl(websocket.PongMessage, []byte(data), time.Now().Add(cfg.WriteTimeout))
		if err != nil {
			c.stop(websocket.CloseTryAgainLater, "slow connection")
		}
		return err
	})
	c.conn.SetCloseHandler(func(code int, _ string) error {
		if code == websocket.CloseNoStatusReceived {
			code = websocket.CloseNormalClosure
		}
		c.stop(code, "")
		return nil
	})
	c.send(response{Op: "ready", Version: 1})
	go c.writeLoop()
	c.readLoop()
	c.stop(websocket.CloseGoingAway, "connection closed")
	<-c.writerDone
}

func (c *client) readLoop() {
	var rate fixedWindow
	for {
		kind, data, err := c.conn.ReadMessage()
		if err != nil {
			if isReadLimit(err) {
				c.stop(websocket.CloseMessageTooBig, "message too large")
			}
			return
		}
		if kind != websocket.TextMessage {
			c.stop(websocket.CloseUnsupportedData, "text messages required")
			return
		}
		if !rate.allow(time.Now(), c.server.cfg.RateWindow, c.server.cfg.MaxRequests) {
			c.stop(websocket.ClosePolicyViolation, "request rate exceeded")
			return
		}
		r, code := parseRequest(data, c.server.cfg.MaxPayloadBytes)
		if code != "" {
			c.send(response{Op: "error", RequestID: r.RequestID, Code: code})
		} else {
			c.server.handle(c, r)
		}
		if c.stopped.Load() {
			return
		}
	}
}

// A read-limit failure can leave a declared oversized frame unread in TCP.
// Closing immediately with unread incoming bytes can send RST on Windows/Linux,
// hiding an already-written 1009 from native clients. Never resume WS parsing:
// half-close outgoing TCP and discard at most this much raw input, with one
// shared absolute close deadline. A malicious endless sender remains bounded.
const maxCloseDrainBytes int64 = 128 << 10

type underlyingTransport interface{ UnderlyingConn() net.Conn }

func drainRejectedMessage(conn net.Conn, deadline time.Time) {
	if err := conn.SetReadDeadline(deadline); err != nil {
		return
	}
	if half, ok := conn.(interface{ CloseWrite() error }); ok {
		if err := half.CloseWrite(); err != nil {
			return
		}
	}
	_, _ = io.CopyN(io.Discard, conn, maxCloseDrainBytes)
}

func (c *client) finishWriter() {
	// Queued events are deliberately discarded on close. Delivery is best-effort.
	deadline := time.Now().Add(c.server.cfg.WriteTimeout)
	_ = c.conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(c.reason.code, c.reason.text), deadline)
	if c.reason.code == websocket.CloseMessageTooBig {
		if transport, ok := c.conn.(underlyingTransport); ok {
			drainRejectedMessage(transport.UnderlyingConn(), deadline)
		}
	}
}

func (c *client) writeLoop() {
	defer close(c.writerDone)
	defer c.conn.Close()
	ticker := time.NewTicker(c.server.cfg.PingInterval)
	defer ticker.Stop()
	for {
		// Prefer termination over draining a stale queue.
		select {
		case <-c.done:
			c.finishWriter()
			return
		default:
		}
		select {
		case <-c.done:
			c.finishWriter()
			return
		case data := <-c.out:
			if c.stopped.Load() {
				continue
			}
			if c.conn.SetWriteDeadline(time.Now().Add(c.server.cfg.WriteTimeout)) != nil || c.conn.WriteMessage(websocket.TextMessage, data) != nil {
				c.stop(websocket.CloseTryAgainLater, "slow connection")
				c.finishWriter()
				return
			}
		case <-ticker.C:
			if err := c.conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(c.server.cfg.WriteTimeout)); err != nil {
				c.stop(websocket.CloseTryAgainLater, "slow connection")
				c.finishWriter()
				return
			}
		}
	}
}

var _ wsTransport = (*websocket.Conn)(nil)
