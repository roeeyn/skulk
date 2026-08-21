// Package testrelay is a minimal in-process protocol v0 relay for client tests.
//
// It is NOT skulkd. It implements just enough of the wire to exercise the client
// — create, join, chat, presence, ping — with none of the relay's real concerns
// (TTL, argon2, capacity, supervision). The authoritative relay behaviour is
// tested in skulkd; the authoritative wire behaviour is the golden corpus, which
// both sides already validate against.
//
// Nothing in cmd/ imports this, so it never reaches a shipped binary.
package testrelay

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/roeeyn/skulk/internal/protocol"
)

// Relay is a fake relay listening on a local httptest server.
type Relay struct {
	server *httptest.Server

	mu    sync.Mutex
	rooms map[string]*room
	pings int
}

// Every connection is its own goroutine, so room state needs a lock. The real
// relay does not: skulkd gives each room a GenServer, and the process IS the
// concurrency control. This is the cost of not being that.
type room struct {
	mu       sync.Mutex
	password string
	members  []*member
	sequence int
	history  []map[string]any
}

type member struct {
	senderID string
	username string
	conn     *websocket.Conn
}

// New starts a relay. Close it with Stop.
func New() *Relay {
	r := &Relay{rooms: map[string]*room{}}
	r.server = httptest.NewServer(http.HandlerFunc(r.handle))
	return r
}

// URL is the ws:// endpoint to hand a client. It is a loopback address, so the
// client's §7.2 policy accepts plain ws:// without --allow-insecure.
func (r *Relay) URL() string {
	return "ws" + strings.TrimPrefix(r.server.URL, "http") + "/v1/ws"
}

func (r *Relay) Stop() { r.server.Close() }

// Pings is how many application-level pings this relay has answered.
func (r *Relay) Pings() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.pings
}

func (r *Relay) handle(w http.ResponseWriter, req *http.Request) {
	conn, err := websocket.Accept(w, req, nil)
	if err != nil {
		return
	}
	conn.SetReadLimit(8 << 20)
	defer conn.CloseNow()

	var joined *room
	var self *member

	for {
		typ, data, err := conn.Read(context.Background())
		if err != nil {
			r.removeMember(joined, self)
			return
		}

		kind := protocol.KindText
		if typ == websocket.MessageBinary {
			kind = protocol.KindBinary
		}

		// The fake relay validates with the same codec the real one does, so a
		// client bug that produces an invalid frame fails here rather than being
		// quietly accepted by a permissive stub.
		frame, rej := protocol.Decode(protocol.RoleRelay, kind, data)
		if rej != nil {
			send(conn, errorFrame(rej.Code, ""))
			if rej.Close {
				return
			}
			continue
		}

		joined, self = r.dispatch(conn, frame, joined, self)
	}
}

func (r *Relay) dispatch(conn *websocket.Conn, frame protocol.Frame, joined *room, self *member) (*room, *member) {
	payload := frame.Payload

	switch frame.Type {
	case "create.begin":
		roomID := payload["room_id"].(string)

		r.mu.Lock()
		if _, exists := r.rooms[roomID]; exists {
			r.mu.Unlock()
			send(conn, errorFrame(protocol.CodeRoomAlreadyExists, frame.RequestID))
			return joined, self
		}
		rm := &room{password: payload["password"].(string)}
		r.rooms[roomID] = rm
		r.mu.Unlock()

		m := rm.admit(conn)
		send(conn, protocol.Frame{
			V: protocol.Version, Type: "create.ok", RequestID: frame.RequestID,
			Payload: map[string]any{
				"room_id": roomID, "sender_id": m.senderID, "username": m.username,
				"expires_at":   stamp(time.Now().Add(120 * time.Hour)),
				"participants": rm.roster(),
			},
		})
		return rm, m

	case "join.begin":
		roomID := payload["room_id"].(string)

		r.mu.Lock()
		rm, exists := r.rooms[roomID]
		r.mu.Unlock()

		if !exists {
			send(conn, errorFrame(protocol.CodeRoomNotFound, frame.RequestID))
			return joined, self
		}
		if rm.password != payload["password"].(string) {
			send(conn, errorFrame(protocol.CodeAuthenticationFailed, frame.RequestID))
			return joined, self
		}

		m := rm.admit(conn)
		send(conn, protocol.Frame{
			V: protocol.Version, Type: "join.ok", RequestID: frame.RequestID,
			Payload: map[string]any{
				"room_id": roomID, "sender_id": m.senderID, "username": m.username,
				"expires_at":   stamp(time.Now().Add(120 * time.Hour)),
				"participants": rm.roster(),
				"history":      rm.snapshot(), "snapshot_sequence": rm.sequence,
			},
		})
		rm.broadcast(protocol.Frame{
			V: protocol.Version, Type: "presence.joined",
			Payload: map[string]any{
				"sender_id": m.senderID, "username": m.username,
				"participant_count": rm.size(),
			},
		}, m)
		return rm, m

	case "chat.send":
		if joined == nil {
			send(conn, errorFrame(protocol.CodeRoomNotFound, frame.RequestID))
			return joined, self
		}
		joined.post(r.roomIDOf(joined), self, payload["message_id"].(string), payload["text"].(string))
		return joined, self

	case "presence.list":
		if joined == nil {
			send(conn, errorFrame(protocol.CodeRoomNotFound, frame.RequestID))
			return joined, self
		}
		send(conn, protocol.Frame{
			V: protocol.Version, Type: "presence.list", RequestID: frame.RequestID,
			Payload: map[string]any{
				"participants": joined.roster(), "participant_count": joined.size(),
			},
		})
		return joined, self

	case "ping":
		r.mu.Lock()
		r.pings++
		r.mu.Unlock()

		send(conn, protocol.Frame{
			V: protocol.Version, Type: "pong", RequestID: frame.RequestID,
			Payload: map[string]any{},
		})
		return joined, self
	}
	return joined, self
}

// Expire pushes room.expired to every member of a room, as the real relay does
// when a TTL elapses.
func (r *Relay) Expire(roomID string) {
	r.mu.Lock()
	rm := r.rooms[roomID]
	delete(r.rooms, roomID)
	r.mu.Unlock()

	if rm == nil {
		return
	}
	rm.broadcast(protocol.Frame{
		V: protocol.Version, Type: "room.expired",
		Payload: map[string]any{"room_id": roomID, "expired_at": stamp(time.Now())},
	}, nil)
}

func (r *Relay) roomIDOf(target *room) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	for id, rm := range r.rooms {
		if rm == target {
			return id
		}
	}
	return ""
}

func (r *Relay) removeMember(rm *room, m *member) {
	if rm == nil || m == nil {
		return
	}
	rm.remove(m)
	rm.broadcast(protocol.Frame{
		V: protocol.Version, Type: "presence.left",
		Payload: map[string]any{
			"sender_id": m.senderID, "username": m.username,
			"participant_count": rm.size(),
		},
	}, nil)
}

var counter struct {
	sync.Mutex
	n int
}

func (rm *room) admit(conn *websocket.Conn) *member {
	counter.Lock()
	counter.n++
	n := counter.n
	counter.Unlock()

	rm.mu.Lock()
	defer rm.mu.Unlock()

	m := &member{
		senderID: fmt.Sprintf("%022d", n),
		username: fmt.Sprintf("quiet-otter-%02d", n%100),
		conn:     conn,
	}
	rm.members = append(rm.members, m)
	return m
}

func (rm *room) remove(target *member) {
	rm.mu.Lock()
	defer rm.mu.Unlock()

	kept := rm.members[:0]
	for _, m := range rm.members {
		if m != target {
			kept = append(kept, m)
		}
	}
	rm.members = kept
}

func (rm *room) size() int {
	rm.mu.Lock()
	defer rm.mu.Unlock()
	return len(rm.members)
}

func (rm *room) seq() int {
	rm.mu.Lock()
	defer rm.mu.Unlock()
	return rm.sequence
}

func (rm *room) roster() []any {
	rm.mu.Lock()
	defer rm.mu.Unlock()

	out := make([]any, 0, len(rm.members))
	for _, m := range rm.members {
		out = append(out, map[string]any{"sender_id": m.senderID, "username": m.username})
	}
	return out
}

func (rm *room) snapshot() []any {
	rm.mu.Lock()
	defer rm.mu.Unlock()

	out := make([]any, 0, len(rm.history))
	for _, h := range rm.history {
		out = append(out, h)
	}
	return out
}

func (rm *room) post(roomID string, sender *member, messageID, text string) {
	rm.mu.Lock()
	rm.sequence++
	payload := map[string]any{
		"room_id": roomID, "message_id": messageID,
		"sender_id": sender.senderID, "sender_username": sender.username,
		"sequence": rm.sequence, "received_at": stamp(time.Now()),
		"text": text,
	}
	rm.history = append(rm.history, payload)
	rm.mu.Unlock()

	// Amendment A11: the sender receives its own message too, byte-identical.
	rm.broadcast(protocol.Frame{V: protocol.Version, Type: "chat.message", Payload: payload}, nil)
}

func (rm *room) broadcast(frame protocol.Frame, except *member) {
	// Copy under the lock, write outside it: a slow socket must not hold the room.
	rm.mu.Lock()
	targets := make([]*member, 0, len(rm.members))
	for _, m := range rm.members {
		if m != except {
			targets = append(targets, m)
		}
	}
	rm.mu.Unlock()

	for _, m := range targets {
		send(m.conn, frame)
	}
}

func errorFrame(code, requestID string) protocol.Frame {
	return protocol.Frame{
		V: protocol.Version, Type: "error", RequestID: requestID,
		Payload: map[string]any{"code": code, "message": strings.ReplaceAll(code, "_", " ")},
	}
}

func send(conn *websocket.Conn, frame protocol.Frame) {
	encoded, err := protocol.Encode(frame)
	if err != nil {
		return
	}
	_ = conn.Write(context.Background(), websocket.MessageText, encoded)
}

func stamp(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000Z")
}

// Decode is a convenience for tests reading the client's stdout.
func Decode(line string) map[string]any {
	var out map[string]any
	_ = json.Unmarshal([]byte(line), &out)
	return out
}
