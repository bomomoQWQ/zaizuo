package relay

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

const testToken = "test-only-relay-token-not-a-real-secret-123456789"
const topicA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const topicB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

func TestSharedVectors(t *testing.T) {
	data, err := os.ReadFile("../protocol/relay-v1-cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct {
		Version int               `json:"version"`
		Valid   []json.RawMessage `json:"valid"`
		Invalid []struct {
			Request json.RawMessage `json:"request"`
			Code    string          `json:"code"`
		} `json:"invalid"`
	}
	if err := json.Unmarshal(data, &vectors); err != nil {
		t.Fatal(err)
	}
	if vectors.Version != 1 || len(vectors.Valid) == 0 || len(vectors.Invalid) == 0 {
		t.Fatal("missing relay-v1 vectors")
	}
	for i, raw := range vectors.Valid {
		if _, code := parseRequest(raw, DefaultMaxPayloadBytes); code != "" {
			t.Errorf("valid[%d]: %s", i, code)
		}
	}
	for i, invalid := range vectors.Invalid {
		if _, code := parseRequest(invalid.Request, DefaultMaxPayloadBytes); code != invalid.Code {
			t.Errorf("invalid[%d]: got %s want %s", i, code, invalid.Code)
		}
	}
	// Exercise the exact same raw vectors across a real httptest WebSocket,
	// not only the isolated parser. Publish needs a prior subscription.
	_, ts := startRelay(t, nil)
	c := dialClient(t, ts)
	for i, raw := range vectors.Valid {
		r, _ := parseRequest(raw, DefaultMaxPayloadBytes)
		if r.Op == "publish" {
			subscribe(t, c, "vector_setup", r.Topic)
		}
		if err := c.WriteMessage(websocket.TextMessage, raw); err != nil {
			t.Fatal(err)
		}
		got := readResponse(t, c)
		if got.Op != "ok" || got.RequestID != r.RequestID || got.For != r.Op || got.Topic != r.Topic {
			t.Fatalf("valid wire vector %d: %+v", i, got)
		}
	}
	for i, invalid := range vectors.Invalid {
		r, _ := parseRequest(invalid.Request, DefaultMaxPayloadBytes)
		if err := c.WriteMessage(websocket.TextMessage, invalid.Request); err != nil {
			t.Fatal(err)
		}
		got := readResponse(t, c)
		if got.Op != "error" || got.Code != invalid.Code || got.RequestID != r.RequestID {
			t.Fatalf("invalid wire vector %d: %+v", i, got)
		}
	}
}

func TestStrictRequestParsing(t *testing.T) {
	cases := []struct {
		name  string
		input string
		id    string
		code  string
	}{
		{"null", `null`, "", codeBadRequest},
		{"array", `[]`, "", codeBadRequest},
		{"scalar", `"subscribe"`, "", codeBadRequest},
		{"trailing", `{"op":"subscribe","request_id":"ok","topic":"` + topicA + `"} {}`, "", codeBadRequest},
		{"null id", `{"op":"subscribe","request_id":null,"topic":"` + topicA + `"}`, "", codeBadRequest},
		{"number id", `{"op":"subscribe","request_id":1,"topic":"` + topicA + `"}`, "", codeBadRequest},
		{"long id", `{"op":"subscribe","request_id":"` + strings.Repeat("x", 65) + `","topic":"` + topicA + `"}`, "", codeBadRequest},
		{"non ascii id", `{"op":"subscribe","request_id":"编号","topic":"` + topicA + `"}`, "", codeBadRequest},
		{"null op", `{"op":null,"request_id":"ok"}`, "ok", codeBadRequest},
		{"number topic", `{"op":"subscribe","request_id":"ok","topic":3}`, "ok", codeBadRequest},
		{"null topic", `{"op":"subscribe","request_id":"ok","topic":null}`, "ok", codeBadRequest},
		{"payload on subscribe", `{"op":"subscribe","request_id":"ok","topic":"` + topicA + `","payload":"AQID"}`, "ok", codeBadRequest},
		{"case-sensitive field", `{"Op":"subscribe","request_id":"ok","topic":"` + topicA + `"}`, "ok", codeBadRequest},
		{"null payload", `{"op":"publish","request_id":"ok","topic":"` + topicA + `","payload":null}`, "ok", codeBadRequest},
		{"boolean payload", `{"op":"publish","request_id":"ok","topic":"` + topicA + `","payload":true}`, "ok", codeBadRequest},
		{"padding required", `{"op":"publish","request_id":"ok","topic":"` + topicA + `","payload":"AQI"}`, "ok", codeBadRequest},
		{"nonzero pad bits", `{"op":"publish","request_id":"ok","topic":"` + topicA + `","payload":"AR=="}`, "ok", codeBadRequest},
		{"urlsafe", `{"op":"publish","request_id":"ok","topic":"` + topicA + `","payload":"__8="}`, "ok", codeBadRequest},
		{"base64 newline", `{"op":"publish","request_id":"ok","topic":"` + topicA + `","payload":"AQID\n"}`, "ok", codeBadRequest},
		{"unknown", `{"op":"unknown","request_id":"ok"}`, "ok", codeUnsupportedOp},
		{"unknown missing id", `{"op":"unknown"}`, "", codeBadRequest},
		{"invalid utf8", string([]byte{'{', '"', 'x', '"', ':', '"', 0xff, '"', '}'}), "", codeBadRequest},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r, code := parseRequest([]byte(tc.input), DefaultMaxPayloadBytes)
			if code != tc.code || r.RequestID != tc.id {
				t.Fatalf("got code=%s id=%q want code=%s id=%q", code, r.RequestID, tc.code, tc.id)
			}
		})
	}
	for _, n := range []int{1, 2, 3, DefaultMaxPayloadBytes, DefaultMaxPayloadBytes + 1} {
		payload := base64.StdEncoding.EncodeToString(make([]byte, n))
		raw, _ := json.Marshal(map[string]string{"op": "publish", "request_id": "size", "topic": topicA, "payload": payload})
		_, code := parseRequest(raw, DefaultMaxPayloadBytes)
		if (code == "") != (n <= DefaultMaxPayloadBytes) {
			t.Errorf("decoded length %d: %s", n, code)
		}
	}
}

func TestTokenValidationAndConfiguration(t *testing.T) {
	for _, token := range []string{"", strings.Repeat("x", 31), strings.Repeat("x", 257), strings.Repeat("x", 31) + " ", strings.Repeat("x", 31) + "\n", strings.Repeat("x", 31) + "\x7f", strings.Repeat("x", 31) + "中"} {
		if ValidateToken(token) == nil {
			t.Error("invalid token accepted")
		}
	}
	for _, n := range []int{32, 256} {
		if err := ValidateToken(strings.Repeat("!", n)); err != nil {
			t.Fatal(err)
		}
	}
	cfg := DefaultConfig(testToken)
	if cfg.MaxConnections != 128 || cfg.MaxTopics != 64 || cfg.MaxMessageBytes != 65536 || cfg.MaxPayloadBytes != 32768 || cfg.QueueCapacity != 32 || cfg.MaxRequests != 100 || cfg.RateWindow != 10*time.Second || cfg.PingInterval != 30*time.Second || cfg.WriteTimeout != 5*time.Second {
		t.Fatal("protocol defaults changed")
	}
	mutations := []func(*Config){
		func(c *Config) { c.Token = "" }, func(c *Config) { c.MaxConnections = 0 }, func(c *Config) { c.MaxTopics = -1 },
		func(c *Config) { c.MaxMessageBytes = 0 }, func(c *Config) { c.MaxPayloadBytes = 0 }, func(c *Config) { c.QueueCapacity = 0 },
		func(c *Config) { c.MaxRequests = 0 }, func(c *Config) { c.RateWindow = 0 }, func(c *Config) { c.PingInterval = 0 }, func(c *Config) { c.WriteTimeout = 0 },
		func(c *Config) { c.PingInterval = time.Duration(1<<63 - 1) },
		func(c *Config) { c.WriteTimeout = time.Duration(1<<63 - 1) },
		func(c *Config) { c.MaxPayloadBytes = DefaultMaxPayloadBytes + 1 },
	}
	for i, mutate := range mutations {
		c := DefaultConfig(testToken)
		mutate(&c)
		if _, err := New(c); err == nil {
			t.Errorf("bad config %d accepted", i)
		}
	}
	s, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if s.cfg.Token != "" {
		t.Fatal("raw token retained in config")
	}
	lower := DefaultConfig(testToken)
	lower.MaxPayloadBytes = 1
	if _, err := New(lower); err != nil {
		t.Fatalf("positive lowered payload limit rejected: %v", err)
	}
}

func TestFixedWindow(t *testing.T) {
	var f fixedWindow
	now := time.Unix(100, 0)
	if !f.allow(now, time.Second, 2) || !f.allow(now.Add(time.Millisecond), time.Second, 2) || f.allow(now.Add(time.Second-time.Nanosecond), time.Second, 2) || !f.allow(now.Add(time.Second), time.Second, 2) {
		t.Fatal("fixed-window boundary incorrect")
	}
}
