// Package relay is the client's WebSocket session with a skulkd relay: connect,
// create or join a room, send messages, and receive everything the relay pushes.
//
// It is transport plus correlation and nothing else. Frame validation lives in
// internal/protocol; the headless line protocol and the TUI are both built on top
// of this package rather than beside it.
package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"

	"github.com/roeeyn/skulk/internal/protocol"
)

// Info is what a successful create or join yields: this connection's identity in
// the room, plus the room state at the moment of admission.
type Info struct {
	RoomID           string
	SenderID         string
	Username         string
	Password         string // set by Create; the generated passphrase must reach the caller
	ExpiresAt        string
	Participants     []Participant
	History          []Message
	SnapshotSequence int
}

type Participant struct {
	SenderID string `json:"sender_id"`
	Username string `json:"username"`
}

type Message struct {
	MessageID      string `json:"message_id"`
	SenderID       string `json:"sender_id"`
	SenderUsername string `json:"sender_username"`
	Sequence       int    `json:"sequence"`
	ReceivedAt     string `json:"received_at"`
	Text           string `json:"text"`
}

// Event is something the relay pushed without being asked.
type Event struct {
	Kind     EventKind
	Message  Message
	Presence Presence
	RoomID   string
	At       string
	Reason   string
}

type EventKind string

const (
	EventMessage     EventKind = "message"
	EventPresence    EventKind = "presence"
	EventRoomExpired EventKind = "room_expired"
	EventDisconnect  EventKind = "disconnected"
)

type Presence struct {
	Action           string
	SenderID         string
	Username         string
	ParticipantCount int
}

// Error is a relay-reported failure carrying a protocol v0 §6 code.
type Error struct {
	Code    string
	Message string
}

func (e *Error) Error() string { return fmt.Sprintf("relay: %s (%s)", e.Message, e.Code) }

// Code returns the protocol v0 error code of err, or "" if err is not a relay error.
func Code(err error) string {
	var re *Error
	if errors.As(err, &re) {
		return re.Code
	}
	return ""
}

// Session is one connection to one relay, and — after Create or Join — one room.
type Session struct {
	conn   *websocket.Conn
	events chan Event

	done chan struct{}

	mu       sync.Mutex
	pending  map[string]chan result
	closed   bool
	senderID string
	roomID   string

	closeOnce sync.Once
}

type result struct {
	frame protocol.Frame
	err   error
}

// DefaultKeepalive is how often an otherwise idle session sends a protocol ping.
//
// It has to be comfortably under the relay's WebSocket idle timeout, which Bandit
// enforces by closing the connection with code 1002. Ten minutes of not typing is
// ordinary — you read a long message and think about it — so without this a healthy
// session dies of silence.
const DefaultKeepalive = 2 * time.Minute

// Options tune a session. The zero value is what production uses.
type Options struct {
	// Keepalive is the ping interval. Zero means DefaultKeepalive; negative
	// disables keepalives entirely (tests that assert timeout behaviour want that).
	Keepalive time.Duration
}

// Dial connects to a relay. The URL must already have passed CheckServerURL.
func Dial(ctx context.Context, endpoint string) (*Session, error) {
	return DialWithOptions(ctx, endpoint, Options{})
}

// DialWithOptions is Dial with the knobs exposed, for tests.
func DialWithOptions(ctx context.Context, endpoint string, opts Options) (*Session, error) {
	conn, _, err := websocket.Dial(ctx, endpoint, nil)
	if err != nil {
		return nil, fmt.Errorf("connecting to relay: %w", err)
	}

	// A join.ok carries the room's whole retained history in one frame — up to
	// 4 MiB at spec §8's caps. The library's default read limit is 32 KiB, which
	// would turn a busy room into an unexplained disconnect.
	conn.SetReadLimit(8 << 20)

	s := &Session{
		conn:    conn,
		events:  make(chan Event, 64),
		pending: make(map[string]chan result),
		done:    make(chan struct{}),
	}
	go s.read()

	if interval := opts.Keepalive; interval >= 0 {
		if interval == 0 {
			interval = DefaultKeepalive
		}
		go s.keepalive(interval)
	}
	return s, nil
}

// keepalive answers the relay's idle timeout with the thing protocol v0 §5.10
// specified for it. The relay replies `pong` and — per spec §14 — a ping does NOT
// refresh the room's TTL, so this keeps the CONNECTION alive without keeping rooms
// alive: a room still expires after its inactivity window regardless of how many
// clients are politely holding sockets open.
func (s *Session) keepalive(interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-s.done:
			return
		case <-ticker.C:
			ctx, cancel := context.WithTimeout(context.Background(), interval)
			err := s.Ping(ctx)
			cancel()

			if err != nil {
				// The read loop owns disconnect reporting; a failed ping just means
				// there is nothing left to keep alive.
				return
			}
		}
	}
}

// Events yields everything the relay pushes unprompted. It is closed when the
// session ends; the final event is always EventDisconnect or EventRoomExpired.
func (s *Session) Events() <-chan Event { return s.events }

// SenderID is this connection's room-scoped identity, known after Create or Join.
func (s *Session) SenderID() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.senderID
}

// Create makes a room and joins it. Empty roomID or password are generated by the
// caller before this point — see internal/wordlist.
func (s *Session) Create(ctx context.Context, roomID, password string) (*Info, error) {
	frame, err := s.request(ctx, "create.begin", map[string]any{
		"room_id": roomID, "password": password,
	})
	if err != nil {
		return nil, err
	}
	info := readInfo(frame.Payload)
	info.Password = password
	s.adopt(info)
	return info, nil
}

// Join admits this connection to an existing room. It never creates one (spec §6.2).
func (s *Session) Join(ctx context.Context, roomID, password string) (*Info, error) {
	frame, err := s.request(ctx, "join.begin", map[string]any{
		"room_id": roomID, "password": password,
	})
	if err != nil {
		return nil, err
	}
	info := readInfo(frame.Payload)
	s.adopt(info)
	return info, nil
}

// Send puts a message on the wire and returns the client-generated message_id.
//
// It does NOT wait for the relay to store it: the wire has no ack for chat.send,
// and the A11 echo — a chat.message event carrying this same message_id — is the
// confirmation. That pairing is what lets a caller notice a message that never
// came back, which is amendment A1d's self-suppression check.
func (s *Session) Send(ctx context.Context, text string) (string, error) {
	messageID := uuid.NewString()
	err := s.write(protocol.Frame{
		V: protocol.Version, Type: "chat.send",
		Payload: map[string]any{"message_id": messageID, "text": text},
	})
	if err != nil {
		return "", err
	}
	return messageID, nil
}

// Who returns the current roster (spec §6.3's /who).
func (s *Session) Who(ctx context.Context) ([]Participant, error) {
	frame, err := s.request(ctx, "presence.list", map[string]any{})
	if err != nil {
		return nil, err
	}
	return readParticipants(frame.Payload["participants"]), nil
}

// Ping exercises the application-level liveness round trip (protocol §5.10).
func (s *Session) Ping(ctx context.Context) error {
	_, err := s.request(ctx, "ping", map[string]any{})
	return err
}

// Close ends the session. Safe to call more than once.
func (s *Session) Close() error {
	var err error
	s.closeOnce.Do(func() {
		err = s.conn.Close(websocket.StatusNormalClosure, "")
	})
	return err
}

// --------------------------------------------------------------------------

func (s *Session) adopt(info *Info) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.senderID = info.SenderID
	s.roomID = info.RoomID
}

// request sends a frame and waits for the reply carrying the same request_id.
// Correlation is by request_id because unsolicited pushes interleave freely with
// replies — a presence.joined can arrive between a join.begin and its join.ok.
func (s *Session) request(ctx context.Context, typ string, payload map[string]any) (protocol.Frame, error) {
	requestID := uuid.NewString()
	waiter := make(chan result, 1)

	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return protocol.Frame{}, errors.New("relay: session is closed")
	}
	s.pending[requestID] = waiter
	s.mu.Unlock()

	defer func() {
		s.mu.Lock()
		delete(s.pending, requestID)
		s.mu.Unlock()
	}()

	if err := s.write(protocol.Frame{
		V: protocol.Version, Type: typ, RequestID: requestID, Payload: payload,
	}); err != nil {
		return protocol.Frame{}, err
	}

	select {
	case r := <-waiter:
		return r.frame, r.err
	case <-ctx.Done():
		return protocol.Frame{}, ctx.Err()
	}
}

func (s *Session) write(frame protocol.Frame) error {
	encoded, err := protocol.Encode(frame)
	if err != nil {
		return fmt.Errorf("encoding %s: %w", frame.Type, err)
	}
	return s.conn.Write(context.Background(), websocket.MessageText, encoded)
}

func (s *Session) read() {
	defer s.shutdown()

	for {
		typ, data, err := s.conn.Read(context.Background())
		if err != nil {
			s.fail(disconnectReason(err))
			return
		}

		kind := protocol.KindText
		if typ == websocket.MessageBinary {
			kind = protocol.KindBinary
		}

		// The client validates what the relay sends it, with the same codec and the
		// same corpus the relay uses on the other side. A relay that sends a
		// malformed frame is a relay we cannot trust to have understood ours.
		frame, rej := protocol.Decode(protocol.RoleClient, kind, data)
		if rej != nil {
			s.fail(fmt.Sprintf("relay sent an invalid frame: %s", rej.Code))
			return
		}

		s.route(frame)
	}
}

func (s *Session) route(frame protocol.Frame) {
	if frame.RequestID != "" {
		s.mu.Lock()
		waiter, ok := s.pending[frame.RequestID]
		s.mu.Unlock()

		if ok {
			if frame.Type == "error" {
				waiter <- result{err: &Error{
					Code:    stringOf(frame.Payload["code"]),
					Message: stringOf(frame.Payload["message"]),
				}}
			} else {
				waiter <- result{frame: frame}
			}
			return
		}
	}

	switch frame.Type {
	case "chat.message":
		s.emit(Event{Kind: EventMessage, Message: readMessage(frame.Payload)})

	case "presence.joined", "presence.left":
		s.emit(Event{Kind: EventPresence, Presence: Presence{
			Action:           strings.TrimPrefix(frame.Type, "presence."),
			SenderID:         stringOf(frame.Payload["sender_id"]),
			Username:         stringOf(frame.Payload["username"]),
			ParticipantCount: intOf(frame.Payload["participant_count"]),
		}})

	case "room.expired":
		s.emit(Event{
			Kind:   EventRoomExpired,
			RoomID: stringOf(frame.Payload["room_id"]),
			At:     stringOf(frame.Payload["expired_at"]),
		})

	case "ping":
		// Either peer may ping (protocol §5.10); answer so the relay's liveness
		// check succeeds even while this client is otherwise idle.
		_ = s.write(protocol.Frame{
			V: protocol.Version, Type: "pong", RequestID: frame.RequestID,
			Payload: map[string]any{},
		})

	case "error":
		// An error with no request_id, or one whose request has already given up.
		s.emit(Event{Kind: EventDisconnect, Reason: stringOf(frame.Payload["message"])})
	}
}

func (s *Session) emit(event Event) {
	select {
	case s.events <- event:
	default:
		// A consumer that has stopped reading is not a reason to block the socket.
	}
}

func (s *Session) fail(reason string) {
	s.emit(Event{Kind: EventDisconnect, Reason: reason})
}

func (s *Session) shutdown() {
	close(s.done)

	s.mu.Lock()
	s.closed = true
	waiters := s.pending
	s.pending = map[string]chan result{}
	s.mu.Unlock()

	for _, waiter := range waiters {
		waiter <- result{err: errors.New("relay: connection closed before a reply arrived")}
	}
	close(s.events)
	_ = s.Close()
}

func disconnectReason(err error) string {
	if status := websocket.CloseStatus(err); status != -1 {
		return fmt.Sprintf("relay closed the connection (%d)", status)
	}
	return err.Error()
}

// --------------------------------------------------------------------------

func readInfo(payload map[string]any) *Info {
	info := &Info{
		RoomID:           stringOf(payload["room_id"]),
		SenderID:         stringOf(payload["sender_id"]),
		Username:         stringOf(payload["username"]),
		ExpiresAt:        stringOf(payload["expires_at"]),
		Participants:     readParticipants(payload["participants"]),
		SnapshotSequence: intOf(payload["snapshot_sequence"]),
	}
	if history, ok := payload["history"].([]any); ok {
		for _, entry := range history {
			if object, ok := entry.(map[string]any); ok {
				info.History = append(info.History, readMessage(object))
			}
		}
	}
	return info
}

func readParticipants(value any) []Participant {
	list, _ := value.([]any)
	out := make([]Participant, 0, len(list))
	for _, entry := range list {
		if object, ok := entry.(map[string]any); ok {
			out = append(out, Participant{
				SenderID: stringOf(object["sender_id"]),
				Username: stringOf(object["username"]),
			})
		}
	}
	return out
}

func readMessage(payload map[string]any) Message {
	return Message{
		MessageID:      stringOf(payload["message_id"]),
		SenderID:       stringOf(payload["sender_id"]),
		SenderUsername: stringOf(payload["sender_username"]),
		Sequence:       intOf(payload["sequence"]),
		ReceivedAt:     stringOf(payload["received_at"]),
		Text:           stringOf(payload["text"]),
	}
}

func stringOf(v any) string {
	s, _ := v.(string)
	return s
}

func intOf(v any) int {
	switch n := v.(type) {
	case json.Number:
		i, _ := n.Int64()
		return int(i)
	case float64:
		return int(n)
	case int:
		return n
	}
	return 0
}
