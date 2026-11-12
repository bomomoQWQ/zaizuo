package relay

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"unicode/utf8"
)

const (
	codeBadRequest    = "bad_request"
	codeUnsupportedOp = "unsupported_op"
	codeNotSubscribed = "not_subscribed"
	codeTooManyTopics = "too_many_topics"
)

type request struct {
	Op        string
	RequestID string
	Topic     string
	Payload   string
}

type response struct {
	Op        string `json:"op"`
	Version   int    `json:"version,omitempty"`
	RequestID string `json:"request_id,omitempty"`
	For       string `json:"for,omitempty"`
	Topic     string `json:"topic,omitempty"`
	Payload   string `json:"payload,omitempty"`
	Code      string `json:"code,omitempty"`
}

func encodeResponse(r response) []byte {
	// Only fixed protocol fields, validated IDs/topics and canonical base64 reach
	// this encoder. These values cannot fail JSON encoding.
	b, _ := json.Marshal(r)
	return b
}

func validRequestID(s string) bool {
	if len(s) == 0 || len(s) > 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		b := s[i]
		if !(b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '_' || b == '-') {
			return false
		}
	}
	return true
}

func validTopic(s string) bool {
	if len(s) != 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		if !(s[i] >= 'a' && s[i] <= 'f' || s[i] >= '0' && s[i] <= '9') {
			return false
		}
	}
	return true
}

// rawString does not accept JSON null (encoding/json unmarshals null into an
// unchanged Go string without an error), numbers, arrays or booleans.
func rawString(raw json.RawMessage) (string, bool) {
	if len(raw) < 2 || raw[0] != '"' {
		return "", false
	}
	var s string
	if json.Unmarshal(raw, &s) != nil {
		return "", false
	}
	return s, true
}

// parseRequest rejects wrong types, unknown fields, trailing JSON, invalid UTF-8
// and noncanonical base64. Duplicate keys are undefined by relay-v1; no account
// authorization or other business-security decision relies on any JSON value.
func parseRequest(data []byte, maxPayload int) (request, string) {
	var r request
	if !utf8.Valid(data) {
		return r, codeBadRequest
	}
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		return r, codeBadRequest
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(trimmed, &fields) != nil || fields == nil {
		return r, codeBadRequest
	}
	if id, ok := rawString(fields["request_id"]); ok && validRequestID(id) {
		r.RequestID = id
	}
	op, ok := rawString(fields["op"])
	if !ok || r.RequestID == "" {
		return r, codeBadRequest
	}
	r.Op = op
	if op != "subscribe" && op != "unsubscribe" && op != "publish" {
		return r, codeUnsupportedOp
	}
	for key := range fields {
		if key != "op" && key != "request_id" && key != "topic" && !(op == "publish" && key == "payload") {
			return r, codeBadRequest
		}
	}
	topic, ok := rawString(fields["topic"])
	if !ok || !validTopic(topic) {
		return r, codeBadRequest
	}
	r.Topic = topic
	if op != "publish" {
		return r, ""
	}
	payload, ok := rawString(fields["payload"])
	if !ok || payload == "" || len(payload)%4 != 0 {
		return r, codeBadRequest
	}
	// Bound allocation before decoding. For canonical encoding, each group is
	// four bytes and the final group can represent one to three decoded bytes.
	maxEncoded := (uint64(maxPayload) + 2) / 3 * 4
	if uint64(len(payload)) > maxEncoded {
		return r, codeBadRequest
	}
	decoded, err := base64.StdEncoding.Strict().DecodeString(payload)
	if err != nil || len(decoded) == 0 || len(decoded) > maxPayload || base64.StdEncoding.EncodeToString(decoded) != payload {
		return r, codeBadRequest
	}
	r.Payload = payload
	return r, ""
}
