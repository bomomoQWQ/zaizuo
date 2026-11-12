package relay

import (
	"bufio"
	"context"
	"crypto/subtle"
	"errors"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// Server is a concurrent http.Handler with ephemeral connection/subscription
// tables. Use New to construct it; call Shutdown as well as http.Server.Shutdown
// because net/http does not close upgraded WebSockets. It never logs bodies.
type Server struct {
	cfg      Config
	digest   [32]byte
	mu       sync.Mutex
	closing  bool
	admitted int
	clients  map[*client]struct{}
	upgrades map[*trackedConn]struct{} // hijacked connections whose upgrade response is still being written
	topics   map[string]map[*client]struct{}
	idle     chan struct{}
	upgrader websocket.Upgrader
}

// New validates all configuration before any listening socket is opened.
func New(cfg Config) (*Server, error) {
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	idle := make(chan struct{})
	close(idle)
	s := &Server{
		cfg:      cfg,
		digest:   tokenDigest(cfg.Token),
		clients:  make(map[*client]struct{}),
		upgrades: make(map[*trackedConn]struct{}),
		topics:   make(map[string]map[*client]struct{}),
		idle:     idle,
		upgrader: websocket.Upgrader{
			HandshakeTimeout:  cfg.WriteTimeout,
			ReadBufferSize:    4096,
			WriteBufferSize:   4096,
			EnableCompression: false,
			// ServeHTTP additionally checks header *presence*, including an
			// empty Origin. Keep the upgrader conservative as a second check.
			CheckOrigin: func(r *http.Request) bool { return !hasHeader(r.Header, "Origin") },
		},
	}
	// Keep only the fixed-length digest after construction.
	s.cfg.Token = ""
	return s, nil
}

func hasHeader(h http.Header, name string) bool {
	for key := range h {
		if strings.EqualFold(key, name) {
			return true
		}
	}
	return false
}

func allHeaderValues(h http.Header, name string) []string {
	var result []string
	for key, values := range h {
		if strings.EqualFold(key, name) {
			result = append(result, values...)
		}
	}
	return result
}

func (s *Server) authorized(r *http.Request) bool {
	values := allHeaderValues(r.Header, "Authorization")
	if len(values) != 1 {
		return false
	}
	value := values[0]
	if len(value) < 7 || !strings.EqualFold(value[:7], "Bearer ") {
		return false
	}
	token := value[7:]
	if ValidateToken(token) != nil {
		return false
	}
	got := tokenDigest(token)
	return subtle.ConstantTimeCompare(got[:], s.digest[:]) == 1
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/v1/ws" && r.URL.Path != "/healthz" {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if r.URL.RawQuery != "" || r.URL.ForceQuery {
		http.Error(w, "query not allowed", http.StatusBadRequest)
		return
	}
	if r.URL.Path == "/healthz" {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write([]byte("ok\n"))
		return
	}
	if hasHeader(r.Header, "Origin") {
		http.Error(w, "origin not allowed", http.StatusForbidden)
		return
	}
	if !s.authorized(r) {
		w.Header().Set("WWW-Authenticate", "Bearer")
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if !websocket.IsWebSocketUpgrade(r) {
		http.Error(w, "websocket upgrade required", http.StatusBadRequest)
		return
	}
	// Count pending handshakes, too. Once shutdown starts no new reservation is
	// possible, and idle is closed only after every admitted handler has exited.
	if !s.reserve() {
		http.Error(w, "relay unavailable", http.StatusServiceUnavailable)
		return
	}
	defer s.release()
	upgradeWriter := &upgradeResponseWriter{ResponseWriter: w, server: s}
	conn, err := s.upgrader.Upgrade(upgradeWriter, r, nil)
	if err != nil {
		return
	}
	c := newClient(s, conn)
	if !s.activate(upgradeWriter.conn, c) {
		_ = conn.Close()
		return
	}
	c.run()
}

// An HTTP upgrade hijacks its TCP connection before writing the 101 response.
// Track that intermediate state as well: net/http.Shutdown does not own it, and
// a deadline must be able to interrupt even a handshake write blocked in I/O.
type trackedConn struct {
	net.Conn
	server *Server
}

func (c *trackedConn) CloseWrite() error {
	if half, ok := c.Conn.(interface{ CloseWrite() error }); ok {
		return half.CloseWrite()
	}
	return nil
}

func (c *trackedConn) Close() error {
	c.server.mu.Lock()
	delete(c.server.upgrades, c)
	c.server.mu.Unlock()
	return c.Conn.Close()
}

type upgradeResponseWriter struct {
	http.ResponseWriter
	server *Server
	conn   *trackedConn
}

func (w *upgradeResponseWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	h, ok := w.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, errors.New("HTTP hijacking unsupported")
	}
	conn, rw, err := h.Hijack()
	if err != nil {
		return nil, nil, err
	}
	tracked := &trackedConn{Conn: conn, server: w.server}
	w.server.mu.Lock()
	if w.server.closing {
		w.server.mu.Unlock()
		_ = conn.Close()
		return nil, nil, errors.New("relay unavailable")
	}
	w.server.upgrades[tracked] = struct{}{}
	w.conn = tracked
	w.server.mu.Unlock()
	return tracked, rw, nil
}

func (s *Server) activate(pending *trackedConn, c *client) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.upgrades, pending)
	if s.closing {
		return false
	}
	s.clients[c] = struct{}{}
	return true
}

func (s *Server) reserve() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closing || s.admitted >= s.cfg.MaxConnections {
		return false
	}
	if s.admitted == 0 {
		s.idle = make(chan struct{})
	}
	s.admitted++
	return true
}

func (s *Server) release() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.admitted--
	if s.admitted == 0 {
		close(s.idle)
	}
}

func (s *Server) register(c *client) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closing {
		return false
	}
	s.clients[c] = struct{}{}
	return true
}

func (s *Server) detach(c *client) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for topic := range c.topics {
		delete(s.topics[topic], c)
		if len(s.topics[topic]) == 0 {
			delete(s.topics, topic)
		}
	}
	clear(c.topics)
}

func (s *Server) forget(c *client) {
	s.mu.Lock()
	delete(s.clients, c)
	s.mu.Unlock()
}

// Shutdown rejects new upgrades, stops every WebSocket and waits for admitted
// handlers. A context deadline force-closes sockets, so blocked I/O cannot keep
// the process alive. Calling it repeatedly or concurrently is safe. The relay
// cannot be restarted; construct a new Server for another lifecycle.
func (s *Server) Shutdown(ctx context.Context) error {
	s.mu.Lock()
	s.closing = true
	clients := make([]*client, 0, len(s.clients))
	for c := range s.clients {
		clients = append(clients, c)
	}
	pending := make([]*trackedConn, 0, len(s.upgrades))
	for c := range s.upgrades {
		pending = append(pending, c)
	}
	idle := s.idle
	s.mu.Unlock()
	for _, c := range pending {
		_ = c.Close()
	}
	for _, c := range clients {
		c.stop(websocket.CloseGoingAway, "server shutdown")
	}
	select {
	case <-idle:
		return nil
	case <-ctx.Done():
		for _, c := range clients {
			_ = c.conn.Close()
		}
		return ctx.Err()
	}
}

func (s *Server) handle(c *client, r request) {
	var peers []*client
	var failure string
	s.mu.Lock()
	if c.stopped.Load() {
		s.mu.Unlock()
		return
	}
	switch r.Op {
	case "subscribe":
		if _, exists := c.topics[r.Topic]; !exists {
			if len(c.topics) >= s.cfg.MaxTopics {
				failure = codeTooManyTopics
			} else {
				c.topics[r.Topic] = struct{}{}
				if s.topics[r.Topic] == nil {
					s.topics[r.Topic] = make(map[*client]struct{})
				}
				s.topics[r.Topic][c] = struct{}{}
			}
		}
	case "unsubscribe":
		delete(c.topics, r.Topic)
		delete(s.topics[r.Topic], c)
		if len(s.topics[r.Topic]) == 0 {
			delete(s.topics, r.Topic)
		}
	case "publish":
		if _, subscribed := c.topics[r.Topic]; !subscribed {
			failure = codeNotSubscribed
		} else {
			for peer := range s.topics[r.Topic] {
				if peer != c {
					peers = append(peers, peer)
				}
			}
		}
	}
	s.mu.Unlock()
	if failure != "" {
		c.send(response{Op: "error", RequestID: r.RequestID, Code: failure})
		return
	}
	if r.Op == "publish" {
		event := encodeResponse(response{Op: "event", Topic: r.Topic, Payload: r.Payload})
		// Never hold the registry lock or wait for a recipient's network I/O.
		// A full queue disconnects that recipient, not its publisher or peers.
		for _, peer := range peers {
			peer.enqueue(event)
		}
	}
	c.send(response{Op: "ok", RequestID: r.RequestID, For: r.Op, Topic: r.Topic})
}

// fixedWindow is owned by a single reader; malformed messages count as requests.
type fixedWindow struct {
	start time.Time
	count int
}

func (f *fixedWindow) allow(now time.Time, window time.Duration, limit int) bool {
	if f.start.IsZero() || !now.Before(f.start.Add(window)) {
		f.start, f.count = now, 0
	}
	if f.count >= limit {
		return false
	}
	f.count++
	return true
}

func isReadLimit(err error) bool { return errors.Is(err, websocket.ErrReadLimit) }
