// Package headless implements docs/headless-v1.md: newline-delimited JSON on
// stdin and stdout, so scripts and AI agents can use skulk without a terminal.
//
// This is a versioned contract, not a test seam (amendment A15). Breaking changes
// to what this package emits are breaking releases. docs/headless-v1.md is
// normative; when the two disagree, the document is right.
package headless

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/roeeyn/skulk/internal/protocol"
	"github.com/roeeyn/skulk/internal/relay"
	"github.com/roeeyn/skulk/internal/wordlist"
)

// Version is the headless interface version, independent of the wire protocol
// version (docs/headless-v1.md §2). It changes only when THIS interface changes —
// the M3 E2EE upgrade moves the wire to v3 and leaves this at 1, because the
// client decrypts and keeps emitting the same `text` field.
const Version = 1

// MaxLineBytes caps one stdin line (§3.1). stdout is deliberately uncapped: a
// `joined` event carries the room's whole retained history on one line, up to
// 4 MiB at spec §8's bounds.
const MaxLineBytes = 65536

// Exit codes, docs/headless-v1.md §8 (from spec §17).
const (
	ExitOK        = 0
	ExitFailure   = 1
	ExitUsage     = 2
	ExitTransport = 3
	ExitNoRoom    = 4
	ExitAuth      = 5
	ExitCapacity  = 6
	ExitProtocol  = 7
)

// Client-local error codes, §7.2. Distinct from wire codes, which are exactly
// protocol v0 §6's ten and are relayed unchanged.
const (
	codeInvalidCommand = "invalid_command"
	codeNotJoined      = "not_joined"
	codeAlreadyJoined  = "already_joined"
	codeTransport      = "transport"
)

// Runner is one headless session: one process, one room.
type Runner struct {
	In            io.Reader
	Out           io.Writer
	Err           io.Writer
	Server        string
	AllowInsecure bool
	ClientVersion string

	mu         sync.Mutex // serializes writes: the event pump and the command loop share Out
	session    *relay.Session
	joined     bool
	done       chan struct{}
	pumpDone   chan struct{}
	finishOnce sync.Once
	// Set before a deliberate shutdown, so the event pump can tell "the relay
	// dropped us" from "we hung up". Closing the socket looks identical to the
	// reader either way.
	stopping atomic.Bool
	// Written by whichever of the command loop and the event pump gets there
	// first, read by Run. Atomic because only one of Run's two exit paths has a
	// happens-before edge to the writer.
	exit atomic.Int32
}

type command struct {
	ID      string          `json:"id"`
	Command string          `json:"command"`
	Params  json.RawMessage `json:"params"`
}

// Run drives the session to completion and returns the process exit code. It
// never calls os.Exit, so tests can drive it directly.
func (r *Runner) Run(ctx context.Context) int {
	r.done = make(chan struct{})
	r.exit.Store(ExitOK)

	// §4: ready is the first line on stdout, emitted BEFORE any network activity.
	// It announces the contract, not connectivity, and a harness waits for it.
	r.emit(map[string]any{
		"event":            "ready",
		"headless_version": Version,
		"protocol_version": protocol.Version,
		"client_version":   r.ClientVersion,
	})

	// The command loop runs in its own goroutine because it blocks on stdin, and a
	// terminal event from the relay (room_expired, disconnected) must be able to end
	// the process without waiting for the agent to type something. Whichever
	// finishes first wins; the other is abandoned as the process exits.
	commands := make(chan struct{})
	go func() {
		r.readCommands(ctx)
		close(commands)
	}()

	select {
	case <-commands:
	case <-r.done:
	}

	// Closing the session ends the relay's event stream, which ends the pump. Wait
	// for it: a pump still writing to stdout after Run returns would race whoever
	// reads that output, and in a test that whoever is the assertion.
	if r.session != nil {
		_ = r.session.Close()
	}
	if r.pumpDone != nil {
		<-r.pumpDone
	}
	return int(r.exit.Load())
}

func (r *Runner) readCommands(ctx context.Context) {
	reader := bufio.NewReaderSize(r.In, 4096)

	for {
		line, tooLong, err := readLine(reader, MaxLineBytes)
		if err != nil {
			// §5.5 / decision H2: EOF on stdin is `quit`. A supervising process
			// closes stdin to signal shutdown, and an Elixir Port does so when the
			// port closes — the harness's own shutdown path.
			r.stopping.Store(true)
			r.emit(map[string]any{"event": "bye", "data": map[string]any{}})
			r.finish(ExitOK)
			return
		}
		if tooLong {
			r.clientError("", codeInvalidCommand, fmt.Sprintf("line exceeds %d bytes", MaxLineBytes), false)
			continue
		}
		if strings.TrimSpace(string(line)) == "" {
			continue
		}

		var cmd command
		if err := json.Unmarshal(line, &cmd); err != nil {
			r.clientError("", codeInvalidCommand, "malformed JSON", false)
			continue
		}

		if stop := r.dispatch(ctx, cmd); stop {
			return
		}
	}
}

func (r *Runner) dispatch(ctx context.Context, cmd command) (stop bool) {
	switch cmd.Command {
	case "create":
		return r.create(ctx, cmd)
	case "join":
		return r.join(ctx, cmd)
	case "send":
		return r.send(ctx, cmd)
	case "who":
		return r.who(ctx, cmd)
	case "quit":
		r.stopping.Store(true)
		r.emit(map[string]any{"id": cmd.ID, "event": "bye", "data": map[string]any{}})
		r.finish(ExitOK)
		return true
	default:
		r.clientError(cmd.ID, codeInvalidCommand, fmt.Sprintf("unknown command %q", cmd.Command), false)
		return false
	}
}

type credentials struct {
	RoomID   string `json:"room_id"`
	Password string `json:"password"`
}

func (r *Runner) create(ctx context.Context, cmd command) bool {
	if r.joined {
		r.clientError(cmd.ID, codeAlreadyJoined, "this process already has a room", false)
		return false
	}

	var params credentials
	if err := decodeParams(cmd.Params, &params); err != nil {
		r.clientError(cmd.ID, codeInvalidCommand, err.Error(), false)
		return false
	}

	var err error
	if params.RoomID == "" {
		if params.RoomID, err = wordlist.NewRoomID(); err != nil {
			return r.fatal(cmd.ID, codeTransport, err.Error(), ExitFailure)
		}
	}
	if params.Password == "" {
		if params.Password, err = wordlist.NewPassphrase(); err != nil {
			return r.fatal(cmd.ID, codeTransport, err.Error(), ExitFailure)
		}
	}

	if stop := r.connect(ctx, cmd.ID); stop {
		return true
	}

	info, err := r.session.Create(ctx, params.RoomID, params.Password)
	if err != nil {
		return r.relayFatal(cmd.ID, err)
	}
	r.joined = true
	r.startPump()

	// §5.1: the password is ALWAYS returned, generated or supplied. A generated
	// passphrase no program can read is a passphrase that cannot be shared, which
	// would make unattended create useless.
	r.emit(map[string]any{"id": cmd.ID, "event": "created", "data": map[string]any{
		"room_id":      info.RoomID,
		"password":     info.Password,
		"username":     info.Username,
		"sender_id":    info.SenderID,
		"expires_at":   info.ExpiresAt,
		"participants": participants(info.Participants),
	}})
	return false
}

func (r *Runner) join(ctx context.Context, cmd command) bool {
	if r.joined {
		r.clientError(cmd.ID, codeAlreadyJoined, "this process already has a room", false)
		return false
	}

	var params credentials
	if err := decodeParams(cmd.Params, &params); err != nil {
		r.clientError(cmd.ID, codeInvalidCommand, err.Error(), false)
		return false
	}
	if params.RoomID == "" || params.Password == "" {
		r.clientError(cmd.ID, codeInvalidCommand, "join requires room_id and password", false)
		return false
	}

	if stop := r.connect(ctx, cmd.ID); stop {
		return true
	}

	info, err := r.session.Join(ctx, params.RoomID, params.Password)
	if err != nil {
		return r.relayFatal(cmd.ID, err)
	}
	r.joined = true
	r.startPump()

	r.emit(map[string]any{"id": cmd.ID, "event": "joined", "data": map[string]any{
		"room_id":           info.RoomID,
		"username":          info.Username,
		"sender_id":         info.SenderID,
		"expires_at":        info.ExpiresAt,
		"participants":      participants(info.Participants),
		"history":           messages(info.History, info.SenderID),
		"snapshot_sequence": info.SnapshotSequence,
	}})
	return false
}

func (r *Runner) send(ctx context.Context, cmd command) bool {
	// Shape before state: a malformed command is invalid_command whether or not a
	// session exists. Checking `joined` first would report not_joined for a command
	// that is wrong in a way joining would never fix.
	var params struct {
		Text string `json:"text"`
	}
	if err := decodeParams(cmd.Params, &params); err != nil {
		r.clientError(cmd.ID, codeInvalidCommand, err.Error(), false)
		return false
	}

	if !r.joined {
		r.clientError(cmd.ID, codeNotJoined, "send requires a room: create or join first", false)
		return false
	}

	// No client-side length check (decision H7): the relay's message_too_large is
	// relayed back, so protocol v0 rule V13 stays the single implementation of the
	// bound rather than two that can drift apart.
	messageID, err := r.session.Send(ctx, params.Text)
	if err != nil {
		r.clientError(cmd.ID, codeTransport, err.Error(), false)
		return false
	}

	// §5.3: "on the wire", not "stored". The message event carrying this same
	// message_id is the confirmation — and an accepted whose message never arrives
	// is exactly amendment A1d's self-suppression check.
	r.emit(map[string]any{"id": cmd.ID, "event": "accepted", "data": map[string]any{
		"message_id": messageID,
	}})
	return false
}

func (r *Runner) who(ctx context.Context, cmd command) bool {
	if !r.joined {
		r.clientError(cmd.ID, codeNotJoined, "who requires a room: create or join first", false)
		return false
	}

	roster, err := r.session.Who(ctx)
	if err != nil {
		r.clientError(cmd.ID, relayCode(err), err.Error(), false)
		return false
	}

	r.emit(map[string]any{"id": cmd.ID, "event": "participants", "data": map[string]any{
		"participants":      participants(roster),
		"participant_count": len(roster),
	}})
	return false
}

func (r *Runner) connect(ctx context.Context, id string) bool {
	if r.session != nil {
		return false
	}

	u, err := relay.CheckServerURL(r.Server, r.AllowInsecure)
	if err != nil {
		return r.fatal(id, codeTransport, err.Error(), ExitTransport)
	}

	session, err := relay.Dial(ctx, u.String())
	if err != nil {
		return r.fatal(id, codeTransport, err.Error(), ExitTransport)
	}
	r.session = session

	r.emit(map[string]any{"event": "connected", "data": map[string]any{"server": u.String()}})
	return false
}

func (r *Runner) startPump() {
	r.pumpDone = make(chan struct{})
	go func() {
		defer close(r.pumpDone)
		r.pump()
	}()
}

// pump forwards everything the relay pushes. Started only after a session exists,
// so it never races the create/join response it must follow.
func (r *Runner) pump() {
	for event := range r.session.Events() {
		switch event.Kind {
		case relay.EventMessage:
			r.emit(map[string]any{"event": "message", "data": message(event.Message, r.session.SenderID())})

		case relay.EventPresence:
			r.emit(map[string]any{"event": "presence", "data": map[string]any{
				"action":            event.Presence.Action,
				"sender_id":         event.Presence.SenderID,
				"username":          event.Presence.Username,
				"participant_count": event.Presence.ParticipantCount,
			}})

		case relay.EventRoomExpired:
			r.emit(map[string]any{"event": "room_expired", "data": map[string]any{
				"room_id": event.RoomID, "expired_at": event.At,
			}})
			r.finish(ExitNoRoom)
			return

		case relay.EventDisconnect:
			// §5.5: after `bye`, no `disconnected` — emitting both would make an
			// orderly exit indistinguishable from a failure, and our own Close is
			// what the reader just tripped over.
			if r.stopping.Load() {
				return
			}
			// §6.5: terminal. Spec §20 makes reconnection a fresh join with a new
			// identity, so silently reconnecting would misrepresent continuity.
			r.emit(map[string]any{"event": "disconnected", "data": map[string]any{
				"reason": event.Reason,
			}})
			r.finish(ExitTransport)
			return
		}
	}
}

// --------------------------------------------------------------------------

func (r *Runner) clientError(id, code, message string, fatal bool) {
	r.errorEvent(id, "client", code, message, fatal)
}

func (r *Runner) errorEvent(id, source, code, message string, fatal bool) {
	event := map[string]any{"event": "error", "data": map[string]any{
		"source": source, "code": code, "message": message, "fatal": fatal,
	}}
	if id != "" {
		event["id"] = id
	}
	r.emit(event)
}

// fatal emits the error and ends the process. Decision H1: create/join failures
// are terminal even though the wire keeps the connection open, because a process
// has no one to ask for a corrected password. One process is one join attempt.
func (r *Runner) fatal(id, code, message string, exit int) bool {
	r.clientError(id, code, message, true)
	r.exit.Store(int32(exit))
	return true
}

func (r *Runner) relayFatal(id string, err error) bool {
	code := relayCode(err)
	r.errorEvent(id, "wire", code, relayMessage(err), true)
	r.exit.Store(int32(exitFor(code)))
	return true
}

// finish ends the process after a terminal relay event. Run is waiting on r.done.
func (r *Runner) finish(exit int) {
	r.finishOnce.Do(func() {
		r.exit.Store(int32(exit))
		close(r.done)
	})
}

func (r *Runner) emit(event map[string]any) {
	encoded, err := json.Marshal(event)
	if err != nil {
		fmt.Fprintf(r.Err, "skulk: cannot encode event: %v\n", err)
		return
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	fmt.Fprintf(r.Out, "%s\n", encoded)
	if flusher, ok := r.Out.(interface{ Flush() error }); ok {
		_ = flusher.Flush()
	}
}

func exitFor(code string) int {
	switch code {
	case protocol.CodeRoomNotFound, protocol.CodeRoomExpired:
		return ExitNoRoom
	case protocol.CodeAuthenticationFailed:
		return ExitAuth
	case protocol.CodeRoomFull:
		return ExitCapacity
	case protocol.CodeUnsupportedProtocolVersion:
		return ExitProtocol
	case codeTransport:
		return ExitTransport
	default:
		return ExitFailure
	}
}

func relayCode(err error) string {
	if code := relay.Code(err); code != "" {
		return code
	}
	return codeTransport
}

func relayMessage(err error) string {
	var re *relay.Error
	if errors.As(err, &re) {
		return re.Message
	}
	return err.Error()
}

func decodeParams(raw json.RawMessage, into any) error {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	if err := json.Unmarshal(raw, into); err != nil {
		return fmt.Errorf("params: %v", err)
	}
	return nil
}

func participants(list []relay.Participant) []map[string]any {
	out := make([]map[string]any, 0, len(list))
	for _, p := range list {
		out = append(out, map[string]any{"sender_id": p.SenderID, "username": p.Username})
	}
	return out
}

func messages(list []relay.Message, self string) []map[string]any {
	out := make([]map[string]any, 0, len(list))
	for _, m := range list {
		out = append(out, message(m, self))
	}
	return out
}

// message renders one chat message. `self` is derived locally (decision H6):
// without it every agent reimplements "is this my own echo?" and one that gets it
// wrong replies to itself forever.
func message(m relay.Message, self string) map[string]any {
	return map[string]any{
		"message_id":      m.MessageID,
		"sender_id":       m.SenderID,
		"sender_username": m.SenderUsername,
		"sequence":        m.Sequence,
		"received_at":     m.ReceivedAt,
		"text":            m.Text,
		"self":            m.SenderID == self && self != "",
	}
}

// readLine reads one newline-terminated line, reporting whether it exceeded the
// cap. An over-long line is discarded through its newline so the NEXT line still
// frames correctly — otherwise one oversized command would corrupt every command
// after it.
func readLine(reader *bufio.Reader, max int) (line []byte, tooLong bool, err error) {
	for {
		chunk, isPrefix, err := reader.ReadLine()
		if err != nil {
			return nil, false, err
		}
		line = append(line, chunk...)

		if len(line) > max {
			tooLong = true
			line = nil
		}
		if !isPrefix {
			return line, tooLong, nil
		}
	}
}
