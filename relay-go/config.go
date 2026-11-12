// Package relay implements the in-memory zaizuo relay-v1 protocol.
// It routes opaque payloads; it does not authenticate accounts or decrypt data.
package relay

import (
	"crypto/sha256"
	"fmt"
	"time"
)

const (
	DefaultMaxConnections  = 128
	DefaultMaxTopics       = 64
	DefaultMaxMessageBytes = 65536
	DefaultMaxPayloadBytes = 32768
	DefaultQueueCapacity   = 32
	DefaultMaxRequests     = 100
)

// Config contains positive resource limits. Start with DefaultConfig, then
// override individual limits. The token is validated by New and never logged.
// MaxMessageBytes bounds an entire WebSocket message, including fragmented ones.
type Config struct {
	Token           string
	MaxConnections  int
	MaxTopics       int
	MaxMessageBytes int64
	MaxPayloadBytes int
	QueueCapacity   int
	MaxRequests     int
	RateWindow      time.Duration
	PingInterval    time.Duration
	WriteTimeout    time.Duration
}

// DefaultConfig returns the common relay-v1 resource defaults. An empty token
// remains invalid: callers must supply a local secret before constructing a relay.
func DefaultConfig(token string) Config {
	return Config{
		Token:           token,
		MaxConnections:  DefaultMaxConnections,
		MaxTopics:       DefaultMaxTopics,
		MaxMessageBytes: DefaultMaxMessageBytes,
		MaxPayloadBytes: DefaultMaxPayloadBytes,
		QueueCapacity:   DefaultQueueCapacity,
		MaxRequests:     DefaultMaxRequests,
		RateWindow:      10 * time.Second,
		PingInterval:    30 * time.Second,
		WriteTimeout:    5 * time.Second,
	}
}

// ValidateToken accepts only 32..256 printable, non-whitespace ASCII bytes.
// It deliberately returns a constant error string, not the supplied value.
func ValidateToken(token string) error {
	if len(token) < 32 || len(token) > 256 {
		return fmt.Errorf("relay token must contain 32..256 printable non-whitespace ASCII characters")
	}
	for i := 0; i < len(token); i++ {
		if token[i] < 0x21 || token[i] > 0x7e {
			return fmt.Errorf("relay token must contain 32..256 printable non-whitespace ASCII characters")
		}
	}
	return nil
}

func (c Config) validate() error {
	if err := ValidateToken(c.Token); err != nil {
		return err
	}
	if c.MaxConnections <= 0 || c.MaxTopics <= 0 || c.MaxMessageBytes <= 0 ||
		c.MaxPayloadBytes <= 0 || c.QueueCapacity <= 0 || c.MaxRequests <= 0 ||
		c.RateWindow <= 0 || c.PingInterval <= 0 || c.WriteTimeout <= 0 {
		return fmt.Errorf("all relay resource limits must be positive")
	}
	if c.MaxPayloadBytes > DefaultMaxPayloadBytes {
		return fmt.Errorf("payload limit cannot exceed relay-v1 maximum of 32768 bytes")
	}
	if c.PingInterval > time.Duration(1<<63-1)/2 || c.WriteTimeout > time.Duration(1<<63-1)/2 {
		return fmt.Errorf("heartbeat or write timeout is too large")
	}
	return nil
}

func tokenDigest(token string) [sha256.Size]byte { return sha256.Sum256([]byte(token)) }
