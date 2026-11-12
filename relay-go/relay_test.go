package relay

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

const testWait = 5 * time.Second

func startRelay(t *testing.T, configure func(*Config)) (*Server, *httptest.Server) {
	t.Helper()
	cfg := DefaultConfig(testToken)
	cfg.PingInterval = time.Hour
	cfg.WriteTimeout = time.Second
	if configure != nil {
		configure(&cfg)
	}
	s, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(s) // httptest listens on loopback only
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), testWait)
		defer cancel()
		if err := s.Shutdown(ctx); err != nil {
			t.Error(err)
		}
		httpServer.Close()
	})
	return s, httpServer
}

func wsURL(ts *httptest.Server) string { return "ws" + strings.TrimPrefix(ts.URL, "http") + "/v1/ws" }

func dialClient(t *testing.T, ts *httptest.Server) *websocket.Conn {
	t.Helper()
	h := http.Header{"Authorization": {"Bearer " + testToken}}
	c, res, err := (&websocket.Dialer{HandshakeTimeout: testWait}).Dial(wsURL(ts), h)
	if err != nil {
		if res != nil {
			res.Body.Close()
		}
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	ready := readResponse(t, c)
	if ready.Op != "ready" || ready.Version != 1 {
		t.Fatalf("bad ready: %+v", ready)
	}
	return c
}

func readResponse(t *testing.T, c *websocket.Conn) response {
	t.Helper()
	_ = c.SetReadDeadline(time.Now().Add(testWait))
	kind, data, err := c.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	if kind != websocket.TextMessage {
		t.Fatalf("response type %d", kind)
	}
	var r response
	if err := json.Unmarshal(data, &r); err != nil {
		t.Fatal(err)
	}
	return r
}

func writeRequest(t *testing.T, c *websocket.Conn, op, id, topic, payload string) {
	t.Helper()
	fields := map[string]string{"op": op, "request_id": id, "topic": topic}
	if op == "publish" {
		fields["payload"] = payload
	}
	_ = c.SetWriteDeadline(time.Now().Add(testWait))
	if err := c.WriteJSON(fields); err != nil {
		t.Fatal(err)
	}
}

func assertOK(t *testing.T, c *websocket.Conn, op, id, topic string) {
	t.Helper()
	got := readResponse(t, c)
	if got.Op != "ok" || got.RequestID != id || got.For != op || got.Topic != topic {
		t.Fatalf("got %+v, want %s %s %s", got, op, id, topic)
	}
}

func subscribe(t *testing.T, c *websocket.Conn, id, topic string) {
	t.Helper()
	writeRequest(t, c, "subscribe", id, topic, "")
	assertOK(t, c, "subscribe", id, topic)
}

func expectClose(t *testing.T, c *websocket.Conn, code int) {
	t.Helper()
	_ = c.SetReadDeadline(time.Now().Add(testWait))
	_, _, err := c.ReadMessage()
	if !websocket.IsCloseError(err, code) {
		t.Fatalf("want close %d, got %v", code, err)
	}
}

func TestHTTPAdmission(t *testing.T) {
	_, ts := startRelay(t, nil)
	cases := []struct {
		name, method, path string
		headers            http.Header
		status             int
	}{
		{"health", "GET", "/healthz", nil, 200},
		{"path", "GET", "/missing", nil, 404},
		{"post", "POST", "/v1/ws", nil, 405},
		{"query", "GET", "/v1/ws?token=not-used", nil, 400},
		{"empty query", "GET", "/v1/ws?", nil, 400},
		{"health query", "GET", "/healthz?", nil, 400},
		{"origin before auth", "GET", "/v1/ws", http.Header{"Origin": {"https://example.invalid"}}, 403},
		{"empty origin", "GET", "/v1/ws", http.Header{"Origin": {""}}, 403},
		{"missing auth", "GET", "/v1/ws", nil, 401},
		{"wrong auth", "GET", "/v1/ws", http.Header{"Authorization": {"Bearer " + strings.Repeat("x", 32)}}, 401},
		{"auth query only", "GET", "/v1/ws?access_token=" + testToken, nil, 400},
		{"duplicate auth", "GET", "/v1/ws", http.Header{"Authorization": {"Bearer " + testToken, "Bearer " + testToken}}, 401},
		{"extra bearer space", "GET", "/v1/ws", http.Header{"Authorization": {"Bearer  " + testToken}}, 401},
		{"other scheme", "GET", "/v1/ws", http.Header{"Authorization": {"Basic " + testToken}}, 401},
		{"not websocket", "GET", "/v1/ws", http.Header{"Authorization": {"Bearer " + testToken}}, 400},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req, err := http.NewRequest(tc.method, ts.URL+tc.path, nil)
			if err != nil {
				t.Fatal(err)
			}
			req.Header = tc.headers
			res, err := ts.Client().Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer res.Body.Close()
			body, err := io.ReadAll(res.Body)
			if err != nil {
				t.Fatal(err)
			}
			if res.StatusCode != tc.status {
				t.Fatalf("got %d, want %d", res.StatusCode, tc.status)
			}
			if strings.Contains(string(body), testToken) {
				t.Fatal("token echoed")
			}
			if tc.name == "health" && string(body) != "ok\n" {
				t.Fatal("unexpected health body")
			}
		})
	}
	// Standard HTTP authentication schemes are case insensitive.
	h := http.Header{"Authorization": {"bEaReR " + testToken}}
	c, res, err := websocket.DefaultDialer.Dial(wsURL(ts), h)
	if err != nil {
		if res != nil {
			res.Body.Close()
		}
		t.Fatal(err)
	}
	defer c.Close()
	if got := readResponse(t, c); got.Op != "ready" {
		t.Fatal(got)
	}
}

func TestConnectionLimitAndCompressionDisabled(t *testing.T) {
	_, ts := startRelay(t, func(c *Config) { c.MaxConnections = 1 })
	h := http.Header{"Authorization": {"Bearer " + testToken}}
	d := websocket.Dialer{HandshakeTimeout: testWait, EnableCompression: true}
	c, res, err := d.Dial(wsURL(ts), h)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if res.Header.Get("Sec-WebSocket-Extensions") != "" {
		t.Fatal("compression enabled")
	}
	_ = readResponse(t, c)
	other, res, err := d.Dial(wsURL(ts), h)
	if other != nil {
		other.Close()
	}
	if err == nil || res == nil || res.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("capacity not enforced: %v %+v", err, res)
	}
	res.Body.Close()
}

func TestRoutingUnsubscribeAndNoSelfEcho(t *testing.T) {
	_, ts := startRelay(t, nil)
	publisher := dialClient(t, ts)
	receiver := dialClient(t, ts)
	other := dialClient(t, ts)
	subscribe(t, publisher, "sp", topicA)
	subscribe(t, receiver, "sr", topicA)
	subscribe(t, other, "so", topicB)
	writeRequest(t, publisher, "publish", "p1", topicA, "AQID")
	// An accidental self echo is queued before this ack and fails the assertion.
	assertOK(t, publisher, "publish", "p1", topicA)
	if r := readResponse(t, receiver); r.Op != "event" || r.Topic != topicA || r.Payload != "AQID" || r.RequestID != "" {
		t.Fatal(r)
	}
	writeRequest(t, other, "subscribe", "barrier", topicB, "")
	assertOK(t, other, "subscribe", "barrier", topicB) // no unrelated-topic event
	writeRequest(t, receiver, "unsubscribe", "u1", topicA, "")
	assertOK(t, receiver, "unsubscribe", "u1", topicA)
	writeRequest(t, receiver, "unsubscribe", "u2", topicA, "")
	assertOK(t, receiver, "unsubscribe", "u2", topicA)
	writeRequest(t, publisher, "publish", "p2", topicA, "BA==")
	assertOK(t, publisher, "publish", "p2", topicA) // success with no recipients
	// Publisher ack is a causal barrier: all sends of p2 have been enqueued.
	writeRequest(t, receiver, "unsubscribe", "barrier2", topicA, "")
	assertOK(t, receiver, "unsubscribe", "barrier2", topicA)
	writeRequest(t, receiver, "publish", "denied", topicA, "AQID")
	if r := readResponse(t, receiver); r.Op != "error" || r.Code != codeNotSubscribed || r.RequestID != "denied" {
		t.Fatal(r)
	}
}

func TestTopicLimitAndErrorResponses(t *testing.T) {
	_, ts := startRelay(t, func(c *Config) { c.MaxTopics = 1 })
	c := dialClient(t, ts)
	subscribe(t, c, "s1", topicA)
	subscribe(t, c, "s2", topicA) // idempotent even when at capacity
	writeRequest(t, c, "subscribe", "s3", topicB, "")
	if r := readResponse(t, c); r.Code != codeTooManyTopics || r.RequestID != "s3" {
		t.Fatal(r)
	}
	if err := c.WriteMessage(websocket.TextMessage, []byte(`{"op":"subscribe","request_id":"bad id","topic":"secret-input"}`)); err != nil {
		t.Fatal(err)
	}
	if r := readResponse(t, c); r.Op != "error" || r.Code != codeBadRequest || r.RequestID != "" || r.Topic != "" {
		t.Fatal(r)
	}
	if err := c.WriteMessage(websocket.TextMessage, []byte(`{"op":null,"request_id":"safe_id"}`)); err != nil {
		t.Fatal(err)
	}
	if r := readResponse(t, c); r.Code != codeBadRequest || r.RequestID != "safe_id" {
		t.Fatal(r)
	}
	writeRequest(t, c, "unsubscribe", "u1", topicA, "")
	assertOK(t, c, "unsubscribe", "u1", topicA)
	subscribe(t, c, "s4", topicB)
}

func TestMessageAndRateLimits(t *testing.T) {
	t.Run("binary", func(t *testing.T) {
		_, ts := startRelay(t, nil)
		c := dialClient(t, ts)
		if err := c.WriteMessage(websocket.BinaryMessage, []byte{1, 2, 3}); err != nil {
			t.Fatal(err)
		}
		expectClose(t, c, websocket.CloseUnsupportedData)
	})
	t.Run("oversize", func(t *testing.T) {
		_, ts := startRelay(t, func(c *Config) { c.MaxMessageBytes = 128 })
		c := dialClient(t, ts)
		if err := c.WriteMessage(websocket.TextMessage, []byte(strings.Repeat("x", 129))); err != nil {
			t.Fatal(err)
		}
		expectClose(t, c, websocket.CloseMessageTooBig)
	})
	t.Run("fragmented oversize", func(t *testing.T) {
		_, ts := startRelay(t, func(c *Config) { c.MaxMessageBytes = 5000 })
		c := dialClient(t, ts)
		// A message larger than gorilla's client write buffer is fragmented;
		// each individual frame is below the configured whole-message limit.
		w, err := c.NextWriter(websocket.TextMessage)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = w.Write([]byte(strings.Repeat("x", 3000))); err != nil {
			t.Fatal(err)
		}
		if _, err = w.Write([]byte(strings.Repeat("x", 3000))); err != nil {
			t.Fatal(err)
		}
		if err = w.Close(); err != nil {
			t.Fatal(err)
		}
		expectClose(t, c, websocket.CloseMessageTooBig)
	})
	t.Run("malformed requests count", func(t *testing.T) {
		_, ts := startRelay(t, func(c *Config) { c.MaxRequests = 2 })
		c := dialClient(t, ts)
		for i := 0; i < 2; i++ {
			if err := c.WriteMessage(websocket.TextMessage, []byte(`null`)); err != nil {
				t.Fatal(err)
			}
			if r := readResponse(t, c); r.Code != codeBadRequest {
				t.Fatal(r)
			}
		}
		if err := c.WriteMessage(websocket.TextMessage, []byte(`null`)); err != nil {
			t.Fatal(err)
		}
		expectClose(t, c, websocket.ClosePolicyViolation)
	})
}

func TestShutdownClosesWebSocketsAndRejectsUpgrades(t *testing.T) {
	s, ts := startRelay(t, nil)
	c := dialClient(t, ts)
	subscribe(t, c, "s", topicA)
	ctx, cancel := context.WithTimeout(context.Background(), testWait)
	defer cancel()
	if err := s.Shutdown(ctx); err != nil {
		t.Fatal(err)
	}
	expectClose(t, c, websocket.CloseGoingAway)
	s.mu.Lock()
	clients, topics, admitted := len(s.clients), len(s.topics), s.admitted
	s.mu.Unlock()
	if clients != 0 || topics != 0 || admitted != 0 {
		t.Fatalf("leaked state %d %d %d", clients, topics, admitted)
	}
	if err := s.Shutdown(ctx); err != nil {
		t.Fatal(err)
	}
	h := http.Header{"Authorization": {"Bearer " + testToken}}
	conn, res, err := websocket.DefaultDialer.Dial(wsURL(ts), h)
	if conn != nil {
		conn.Close()
	}
	if err == nil || res == nil || res.StatusCode != 503 {
		t.Fatalf("upgrade after shutdown: %v %+v", err, res)
	}
	res.Body.Close()
}

func TestPingPongAndUnresponsivePeer(t *testing.T) {
	t.Run("pong keeps connection alive", func(t *testing.T) {
		_, ts := startRelay(t, func(c *Config) { c.PingInterval = 100 * time.Millisecond })
		c := dialClient(t, ts)
		pings := make(chan struct{}, 8)
		c.SetPingHandler(func(data string) error {
			err := c.WriteControl(websocket.PongMessage, []byte(data), time.Now().Add(testWait))
			select {
			case pings <- struct{}{}:
			default:
			}
			return err
		})
		got := make(chan response, 1)
		fail := make(chan error, 1)
		go func() {
			_, data, err := c.ReadMessage()
			if err != nil {
				fail <- err
				return
			}
			var r response
			err = json.Unmarshal(data, &r)
			if err != nil {
				fail <- err
				return
			}
			got <- r
		}()
		// Observe several actual pings, not a sleep-based assumption of liveness.
		for i := 0; i < 3; i++ {
			select {
			case <-pings:
			case err := <-fail:
				t.Fatal(err)
			case <-time.After(testWait):
				t.Fatal("no ping")
			}
		}
		writeRequest(t, c, "subscribe", "live", topicA, "")
		select {
		case r := <-got:
			if r.Op != "ok" || r.RequestID != "live" {
				t.Fatal(r)
			}
		case err := <-fail:
			t.Fatal(err)
		case <-time.After(testWait):
			t.Fatal("no response")
		}
	})
	t.Run("missing pong closes", func(t *testing.T) {
		_, ts := startRelay(t, func(c *Config) { c.PingInterval = 100 * time.Millisecond })
		c := dialClient(t, ts)
		c.SetPingHandler(func(string) error { return nil })
		expectClose(t, c, websocket.CloseGoingAway)
	})
}

func TestConcurrentPublishers(t *testing.T) {
	const publishers = 6
	const messages = 20
	_, ts := startRelay(t, func(c *Config) { c.QueueCapacity = 256; c.MaxRequests = 1000 })
	receiver := dialClient(t, ts)
	subscribe(t, receiver, "rx", topicA)
	senders := make([]*websocket.Conn, publishers)
	for i := range senders {
		senders[i] = dialClient(t, ts)
		subscribe(t, senders[i], "s", topicA)
	}
	// Each sender also receives others' events. A per-connection loop performs
	// all reads and checks its own acknowledgements while draining those events.
	start := make(chan struct{})
	errs := make(chan error, publishers)
	var wg sync.WaitGroup
	for n, c := range senders {
		wg.Add(1)
		go func(n int, c *websocket.Conn) {
			defer wg.Done()
			<-start
			for i := 0; i < messages; i++ {
				id := fmt.Sprintf("p_%d_%d", n, i)
				payload := base64.StdEncoding.EncodeToString([]byte(id))
				if err := c.WriteJSON(map[string]string{"op": "publish", "request_id": id, "topic": topicA, "payload": payload}); err != nil {
					errs <- err
					return
				}
				for {
					_ = c.SetReadDeadline(time.Now().Add(testWait))
					_, data, err := c.ReadMessage()
					if err != nil {
						errs <- err
						return
					}
					var r response
					if err = json.Unmarshal(data, &r); err != nil {
						errs <- err
						return
					}
					if r.Op == "ok" && r.RequestID == id {
						break
					}
					if r.Op != "event" {
						errs <- fmt.Errorf("unexpected sender response: %+v", r)
						return
					}
				}
			}
		}(n, c)
	}
	close(start)
	seen := make(map[string]bool)
	for i := 0; i < publishers*messages; i++ {
		r := readResponse(t, receiver)
		if r.Op != "event" || r.Topic != topicA {
			t.Fatal(r)
		}
		b, err := base64.StdEncoding.DecodeString(r.Payload)
		if err != nil {
			t.Fatal(err)
		}
		if seen[string(b)] {
			t.Fatalf("duplicate event %q", b)
		}
		seen[string(b)] = true
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Error(err)
	}
}
