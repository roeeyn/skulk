// Package protocol defines the skulk wire frames (protocol v0 for milestone
// M0). The golden frame corpus under docs/protocol/corpus/ is the contract:
// this package and the Elixir relay (skulkd) must accept/reject every vector
// identically, enforced by contract tests on both sides (design A13).
package protocol

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"unicode/utf8"
)

// Version is the wire protocol version sent in every frame's "v" field.
const Version = 0

// Limits from docs/protocol-v0.md §2.1 and §4.
const (
	MaxRelayFrameBytes   = 16384
	MaxTextBytes         = 4096
	MinPasswordBytes     = 12
	MaxPasswordBytes     = 256
	MaxRoomIDBytes       = 160
	MaxUsernameBytes     = 64
	MaxErrorMessageBytes = 256
	MaxSequence          = 9007199254740991 // 2^53-1, decision D6
)

// Role is the peer that RECEIVED a frame. Validation is parameterized by it
// because the same registry covers both directions: the relay never legitimately
// receives a chat.message, but it must still reject one as a direction violation
// (docs/protocol-v0.md §7.3).
type Role string

const (
	RoleRelay  Role = "relay"
	RoleClient Role = "client"
)

// Kind is the WebSocket frame type. It is an input to validation, not a hint:
// rule V1 rejects every binary frame before anything is parsed.
type Kind string

const (
	KindText   Kind = "text"
	KindBinary Kind = "binary"
)

// Error codes, docs/protocol-v0.md §6. Exactly eleven since M1 (ROJ-39) made
// server_capacity reachable; §17 groups it with room_full on exit code 6.
const (
	CodeRoomNotFound               = "room_not_found"
	CodeRoomAlreadyExists          = "room_already_exists"
	CodeAuthenticationFailed       = "authentication_failed"
	CodeRoomExpired                = "room_expired"
	CodeRoomFull                   = "room_full"
	CodeServerCapacity             = "server_capacity"
	CodeMessageTooLarge            = "message_too_large"
	CodeInvalidMessage             = "invalid_message"
	CodeUnsupportedProtocolVersion = "unsupported_protocol_version"
	CodeUnsupportedFrameType       = "unsupported_frame_type"
	CodeInternalError              = "internal_error"
)

var errorCodes = map[string]bool{
	CodeRoomNotFound: true, CodeRoomAlreadyExists: true, CodeAuthenticationFailed: true,
	CodeRoomExpired: true, CodeRoomFull: true, CodeServerCapacity: true,
	CodeMessageTooLarge: true,
	CodeInvalidMessage:  true, CodeUnsupportedProtocolVersion: true,
	CodeUnsupportedFrameType: true, CodeInternalError: true,
}

var (
	roomIDRe    = regexp.MustCompile(`^[a-z]+(-[a-z]+){7}$`)
	usernameRe  = regexp.MustCompile(`^[a-z]+-[a-z]+-[0-9]{2}$`)
	senderIDRe  = regexp.MustCompile(`^[A-Za-z0-9_-]{22}$`)
	uuid4Re     = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	timestampRe = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$`)
)

// Frame is a decoded protocol v0 envelope. Field order here is the canonical
// encoding order; Payload keys are sorted by encoding/json.
type Frame struct {
	V         int            `json:"v"`
	Type      string         `json:"type"`
	RequestID string         `json:"request_id,omitempty"`
	Payload   map[string]any `json:"payload"`
}

// Rejection is why a frame was refused. Close is a property of the RULE, not the
// code: message_too_large closes on V2 (oversized frame) but not on V13
// (oversized text). See docs/protocol-v0.md §7.1.
type Rejection struct {
	Code  string
	Rule  string
	Close bool
}

func (r *Rejection) Error() string {
	return fmt.Sprintf("protocol v0: %s (rule %s)", r.Code, r.Rule)
}

type direction string

const (
	c2r direction = "c2r"
	r2c direction = "r2c"
)

// Direction reports which way a frame travelled, given who received it.
func Direction(receiver Role) direction {
	if receiver == RoleRelay {
		return c2r
	}
	return r2c
}

type jsonType int

const (
	jsonString jsonType = iota
	jsonInteger
	jsonArray
)

type field struct {
	name  string
	jtype jsonType
	check string
}

type reqIDRule int

const (
	reqRequired reqIDRule = iota
	reqOptional
	reqAbsent
)

type frameSpec struct {
	requestID reqIDRule
	fields    []field
}

type key struct {
	typ string
	dir direction
}

var participantFields = []field{
	{"sender_id", jsonString, "sender_id"},
	{"username", jsonString, "username"},
}

var chatMessageFields = []field{
	{"room_id", jsonString, "room_id"},
	{"message_id", jsonString, "uuid4"},
	{"sender_id", jsonString, "sender_id"},
	{"sender_username", jsonString, "username"},
	{"sequence", jsonInteger, "sequence"},
	{"received_at", jsonString, "timestamp"},
	{"text", jsonString, "text"},
}

var presenceFields = []field{
	{"sender_id", jsonString, "sender_id"},
	{"username", jsonString, "username"},
	{"participant_count", jsonInteger, "count"},
}

var credentialFields = []field{
	{"room_id", jsonString, "room_id"},
	{"password", jsonString, "password"},
}

// The §5 registry, as data. Keyed by (type, direction) because presence.list
// carries a different payload in each direction (decision D7).
var frames = map[key]frameSpec{
	{"create.begin", c2r}: {reqRequired, credentialFields},
	{"create.ok", r2c}: {reqRequired, []field{
		{"room_id", jsonString, "room_id"},
		{"sender_id", jsonString, "sender_id"},
		{"username", jsonString, "username"},
		{"expires_at", jsonString, "timestamp"},
		{"participants", jsonArray, "participants"},
	}},
	{"join.begin", c2r}: {reqRequired, credentialFields},
	{"join.ok", r2c}: {reqRequired, []field{
		{"room_id", jsonString, "room_id"},
		{"sender_id", jsonString, "sender_id"},
		{"username", jsonString, "username"},
		{"expires_at", jsonString, "timestamp"},
		{"participants", jsonArray, "participants"},
		{"history", jsonArray, "history"},
		{"snapshot_sequence", jsonInteger, "snapshot_sequence"},
	}},
	{"chat.send", c2r}: {reqOptional, []field{
		{"message_id", jsonString, "uuid4"},
		{"text", jsonString, "text"},
	}},
	{"chat.message", r2c}:    {reqAbsent, chatMessageFields},
	{"presence.joined", r2c}: {reqAbsent, presenceFields},
	{"presence.left", r2c}:   {reqAbsent, presenceFields},
	{"presence.list", c2r}:   {reqRequired, nil},
	{"presence.list", r2c}: {reqRequired, []field{
		{"participants", jsonArray, "participants"},
		{"participant_count", jsonInteger, "count"},
	}},
	{"room.expired", r2c}: {reqAbsent, []field{
		{"room_id", jsonString, "room_id"},
		{"expired_at", jsonString, "timestamp"},
	}},
	{"ping", c2r}: {reqRequired, nil},
	{"ping", r2c}: {reqRequired, nil},
	{"pong", c2r}: {reqRequired, nil},
	{"pong", r2c}: {reqRequired, nil},
	{"error", r2c}: {reqOptional, []field{
		{"code", jsonString, "error_code"},
		{"message", jsonString, "error_message"},
	}},
}

var knownTypes = func() map[string]bool {
	m := make(map[string]bool)
	for k := range frames {
		m[k.typ] = true
	}
	return m
}()

// Validate reports the protocol v0 error code the receiver must answer with, or
// "" when the frame is valid. This is the golden-corpus contract seam.
func Validate(receiver Role, kind Kind, frame []byte) string {
	if _, rej := Decode(receiver, kind, frame); rej != nil {
		return rej.Code
	}
	return ""
}

// Decode validates and parses one received frame. Rules run in the order given by
// docs/protocol-v0.md §7 and stop at the first failure — the order IS the
// contract, because a malformed frame usually breaks several rules at once and
// without a fixed order Go and Elixir could both be "correct" and still disagree.
func Decode(receiver Role, kind Kind, frame []byte) (Frame, *Rejection) {
	var f Frame
	dir := Direction(receiver)

	// V1 — binary frames have no text interpretation to validate.
	if kind == KindBinary {
		return f, &Rejection{CodeUnsupportedFrameType, "V1", true}
	}

	// V2 — relay only (decision D2). Cheapest defence; must not be reachable past.
	if receiver == RoleRelay && len(frame) > MaxRelayFrameBytes {
		return f, &Rejection{CodeMessageTooLarge, "V2", true}
	}

	// V3 — MUST run before unmarshalling. encoding/json silently replaces invalid
	// UTF-8 with U+FFFD rather than erroring, so letting it parse first would turn
	// a V3 rejection into a spurious accept.
	if !utf8.Valid(frame) {
		return f, &Rejection{CodeInvalidMessage, "V3", true}
	}

	// V4 — parses as JSON, the top level is an object, no key repeats at any depth,
	// and no string carries an unpaired surrogate escape (D13). Both extra checks
	// run HERE rather than as a pre-pass, because §7.1's rule order is the
	// cross-language contract: a frame that breaks several rules at once has to
	// produce the same code in both languages.
	if rej := checkStrictJSON(frame); rej != nil {
		return f, rej
	}

	var envelope map[string]any
	dec := json.NewDecoder(bytes.NewReader(frame))
	dec.UseNumber() // so V5 can tell the integer 0 from the float 0.0
	if err := dec.Decode(&envelope); err != nil {
		return f, &Rejection{CodeInvalidMessage, "V4", true}
	}
	// Nothing may follow the object but whitespace. `dec.More()` is NOT this check
	// and was the bug ROJ-44's differential fuzzing found: it reports whether
	// another element follows in the current array or object, so it answers false
	// precisely when the next byte is `}` or `]` — and `{...}}` sailed through while
	// Elixir rejected it. Asking for the next token instead is unambiguous: a
	// complete frame is followed by io.EOF and nothing else.
	if _, err := dec.Token(); err != io.EOF {
		return f, &Rejection{CodeInvalidMessage, "V4", true}
	}

	// V5 — v is present and is an integer.
	v, ok := integerOf(envelope["v"])
	if !ok {
		return f, &Rejection{CodeInvalidMessage, "V5", true}
	}

	// V6 — after V5, because "missing" and "unsupported" are different diagnoses.
	if v != Version {
		return f, &Rejection{CodeUnsupportedProtocolVersion, "V6", true}
	}

	// V7 — type is present and is a string.
	typ, ok := envelope["type"].(string)
	if !ok {
		return f, &Rejection{CodeInvalidMessage, "V7", true}
	}

	// V8 — after V6: a type cannot be interpreted without the version defining it.
	if !knownTypes[typ] {
		return f, &Rejection{CodeUnsupportedFrameType, "V8", false}
	}

	// V9 — request_id per §4.3. A type in the wrong direction has no §4.3 row, so
	// only the shape check applies; V11 is what rejects it, one rule later.
	spec, pairExists := frames[key{typ, dir}]
	requestID, hasRequestID := envelope["request_id"]
	rule := reqOptional
	if pairExists {
		rule = spec.requestID
	}
	if hasRequestID {
		s, ok := requestID.(string)
		if !ok || !uuid4Re.MatchString(s) {
			return f, &Rejection{CodeInvalidMessage, "V9", false}
		}
	}
	if rule == reqRequired && !hasRequestID {
		return f, &Rejection{CodeInvalidMessage, "V9", false}
	}
	if rule == reqAbsent && hasRequestID {
		return f, &Rejection{CodeInvalidMessage, "V9", false}
	}

	// V10 — payload is present and is an object.
	payload, ok := envelope["payload"].(map[string]any)
	if !ok {
		return f, &Rejection{CodeInvalidMessage, "V10", false}
	}

	// V11 — before V12: a chat.message sent to the relay is a direction violation,
	// not a payload complaint, however well-formed its payload is.
	if !pairExists {
		return f, &Rejection{CodeInvalidMessage, "V11", true}
	}

	// V12 — required fields present with the right JSON type. Unknown payload keys
	// are IGNORED (§3, decision D3): that is how M1-M3 add fields additively.
	if rej := checkFieldTypes(payload, spec.fields, "V12"); rej != nil {
		return f, rej
	}

	// V13 — value bounds and §5's cross-field invariants.
	if rej := checkValues(payload, spec.fields); rej != nil {
		return f, rej
	}
	if rej := checkCrossField(payload); rej != nil {
		return f, rej
	}

	f = Frame{V: v, Type: typ, Payload: payload}
	if hasRequestID {
		f.RequestID = requestID.(string)
	}
	return f, nil
}

// Encode serializes a frame canonically: envelope fields in the §3 order, payload
// keys sorted by encoding/json. Encoding is idempotent, which is what the
// round-trip test asserts — byte-identical output across LANGUAGES is not
// required by anything and deliberately not attempted.
func Encode(f Frame) ([]byte, error) {
	if f.Payload == nil {
		f.Payload = map[string]any{}
	}
	return json.Marshal(f)
}

// integerOf reports whether v is a JSON integer. json.Number keeps the literal
// text, so "0.0" and "1e2" fail here exactly as the corpus requires — an
// any-typed float64 could not tell them from 0 and 100.
func integerOf(v any) (int, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return 0, false
	}
	i, err := n.Int64()
	if err != nil {
		return 0, false
	}
	return int(i), true
}

func checkFieldTypes(payload map[string]any, fields []field, rule string) *Rejection {
	for _, fl := range fields {
		value, present := payload[fl.name]
		if !present {
			return &Rejection{CodeInvalidMessage, rule, false}
		}
		switch fl.jtype {
		case jsonString:
			if _, ok := value.(string); !ok {
				return &Rejection{CodeInvalidMessage, rule, false}
			}
		case jsonInteger:
			if _, ok := integerOf(value); !ok {
				return &Rejection{CodeInvalidMessage, rule, false}
			}
		case jsonArray:
			if _, ok := value.([]any); !ok {
				return &Rejection{CodeInvalidMessage, rule, false}
			}
		}
	}
	return nil
}

func checkValues(payload map[string]any, fields []field) *Rejection {
	for _, fl := range fields {
		if rej := checkValue(payload[fl.name], fl.check); rej != nil {
			return rej
		}
	}
	return nil
}

func checkValue(value any, check string) *Rejection {
	switch check {
	case "room_id":
		return pattern(value.(string), roomIDRe, MaxRoomIDBytes)
	case "username":
		return pattern(value.(string), usernameRe, MaxUsernameBytes)
	case "sender_id":
		return pattern(value.(string), senderIDRe, 0)
	case "uuid4":
		return pattern(value.(string), uuid4Re, 0)
	case "timestamp":
		return pattern(value.(string), timestampRe, 0)

	case "password":
		n := len(value.(string))
		if n < MinPasswordBytes || n > MaxPasswordBytes {
			return invalid()
		}

	case "text":
		// The one V13 failure that is not invalid_message. The bound counts BYTES:
		// an implementation measuring runes accepts frames it must reject.
		n := len(value.(string))
		if n > MaxTextBytes {
			return &Rejection{CodeMessageTooLarge, "V13", false}
		}
		if n < 1 {
			return invalid()
		}

	case "sequence":
		n, _ := integerOf(value)
		if n < 1 || n > MaxSequence {
			return invalid()
		}

	case "snapshot_sequence", "count":
		n, _ := integerOf(value)
		if n < 0 || n > MaxSequence {
			return invalid()
		}

	case "error_code":
		if !errorCodes[value.(string)] {
			return invalid()
		}

	case "error_message":
		n := len(value.(string))
		if n < 1 || n > MaxErrorMessageBytes {
			return invalid()
		}

	case "participants":
		for _, entry := range value.([]any) {
			if rej := checkObject(entry, participantFields); rej != nil {
				return rej
			}
		}

	case "history":
		// Entries are chat.message PAYLOAD objects (§5.4), validated exactly as a
		// live payload would be, and ordered strictly ascending by sequence.
		// Ascending is not contiguous: §15 eviction leaves gaps.
		previous := -1
		for _, entry := range value.([]any) {
			if rej := checkObject(entry, chatMessageFields); rej != nil {
				return rej
			}
			sequence, _ := integerOf(entry.(map[string]any)["sequence"])
			if sequence <= previous {
				return invalid()
			}
			previous = sequence
		}
	}
	return nil
}

func checkObject(value any, fields []field) *Rejection {
	object, ok := value.(map[string]any)
	if !ok {
		return invalid()
	}
	if rej := checkFieldTypes(object, fields, "V13"); rej != nil {
		return rej
	}
	return checkValues(object, fields)
}

// §5's cross-field invariants. Each is skipped when its fields are absent: a
// payload without them either failed V12 already or does not carry them at all.
func checkCrossField(payload map[string]any) *Rejection {
	if participants, ok := payload["participants"].([]any); ok {
		if count, ok := integerOf(payload["participant_count"]); ok {
			if len(participants) != count {
				return invalid()
			}
		}
	}

	if history, ok := payload["history"].([]any); ok {
		if boundary, ok := integerOf(payload["snapshot_sequence"]); ok {
			// Decision D9: 0 for an empty snapshot, never null. Sequences start at
			// 1, so 0 is unambiguous.
			expected := 0
			if len(history) > 0 {
				last, _ := history[len(history)-1].(map[string]any)
				expected, _ = integerOf(last["sequence"])
			}
			if boundary != expected {
				return invalid()
			}
		}
	}
	return nil
}

func pattern(value string, re *regexp.Regexp, maxBytes int) *Rejection {
	if maxBytes > 0 && len(value) > maxBytes {
		return invalid()
	}
	if !re.MatchString(value) {
		return invalid()
	}
	return nil
}

// checkStrictJSON enforces the two halves of D13 that encoding/json will not.
//
// Duplicate keys: encoding/json keeps the LAST occurrence and Jason keeps the
// FIRST, so `{"text":"harmless","text":"actual"}` is a frame the relay validates
// as one thing and every client displays as another. Rejecting removes the shape
// rather than picking a winner.
//
// Unpaired surrogate escapes: V3's UTF-8 scan catches surrogates spelled as raw
// bytes, but `\ud800` as an ESCAPE survives it and is resolved during parsing,
// where encoding/json substitutes U+FFFD and accepts. V3 already decided this —
// valid UTF-8 has no representation for an unpaired surrogate — so this is Go
// coming into spec, not a new rule.
func checkStrictJSON(frame []byte) *Rejection {
	if rej := unpairedSurrogateEscape(frame); rej != nil {
		return rej
	}
	return duplicateKeys(frame)
}

// unpairedSurrogateEscape scans the RAW bytes, not the decoded strings. By the
// time a string is decoded an unpaired surrogate has already become U+FFFD, which
// is indistinguishable from a U+FFFD the sender legitimately typed — and rejecting
// that would be a fresh divergence in the other direction.
//
// Scanning the whole frame rather than tracking string boundaries is safe: a `\u`
// outside a string is unparseable JSON, which V4 rejects with this same code.
func unpairedSurrogateEscape(frame []byte) *Rejection {
	for i := 0; i < len(frame); i++ {
		if frame[i] != '\\' {
			continue
		}
		// `\\` is an escaped backslash: consume both so the character after it is
		// read as literal text rather than as the start of an escape.
		if i+1 < len(frame) && frame[i+1] != 'u' {
			i++
			continue
		}

		value, ok := hex4(frame, i+2)
		if !ok {
			continue // malformed escape; V4's parse rejects it
		}

		switch {
		case value >= 0xD800 && value <= 0xDBFF:
			// A high surrogate is only legal immediately followed by a low one.
			low, ok := hex4(frame, i+8)
			if !ok || i+6 >= len(frame) || frame[i+6] != '\\' || frame[i+7] != 'u' ||
				low < 0xDC00 || low > 0xDFFF {
				return &Rejection{CodeInvalidMessage, "V4", true}
			}
			i += 11
		case value >= 0xDC00 && value <= 0xDFFF:
			// A low surrogate reached on its own: its pair would have consumed it.
			return &Rejection{CodeInvalidMessage, "V4", true}
		default:
			i += 5
		}
	}

	return nil
}

func hex4(frame []byte, at int) (int, bool) {
	if at+4 > len(frame) {
		return 0, false
	}

	value := 0
	for _, b := range frame[at : at+4] {
		switch {
		case b >= '0' && b <= '9':
			value = value<<4 | int(b-'0')
		case b >= 'a' && b <= 'f':
			value = value<<4 | int(b-'a'+10)
		case b >= 'A' && b <= 'F':
			value = value<<4 | int(b-'A'+10)
		default:
			return 0, false
		}
	}
	return value, true
}

// duplicateKeys walks the token stream depth-first. Token order from a
// json.Decoder means each nested value is finished before the next key of its
// parent arrives, so one map per object is enough and no stack is needed.
func duplicateKeys(frame []byte) *Rejection {
	dec := json.NewDecoder(bytes.NewReader(frame))
	dec.UseNumber()
	rej, _ := scanValue(dec)
	return rej
}

// scanValue returns any rejection, and whether the walk can safely continue.
//
// The second return value is not defensive tidiness — without it this function
// spins forever on `[,]`. `More()` reports whether the next byte is something
// other than `]` or `}`, so on a stray comma it keeps promising an element that
// `Token()` cannot deliver, and a loop that treats a token error as "skip this
// one" never advances. That is an unauthenticated caller pinning a relay CPU with
// three bytes. ROJ-44's differential harness caught it before it shipped, which is
// most of the argument for building the harness.
//
// So: any JSON error stops the walk immediately. Diagnosing malformed input is
// Decode's job, one code path deciding one thing.
func scanValue(dec *json.Decoder) (*Rejection, bool) {
	token, err := dec.Token()
	if err != nil {
		return nil, false
	}

	delim, ok := token.(json.Delim)
	if !ok {
		return nil, true // a scalar, already consumed
	}

	switch delim {
	case '{':
		seen := map[string]bool{}
		for dec.More() {
			key, err := dec.Token()
			if err != nil {
				return nil, false
			}
			name, ok := key.(string)
			if !ok {
				return nil, false
			}
			if seen[name] {
				return &Rejection{CodeInvalidMessage, "V4", true}, false
			}
			seen[name] = true

			if rej, ok := scanValue(dec); rej != nil || !ok {
				return rej, false
			}
		}
	case '[':
		for dec.More() {
			if rej, ok := scanValue(dec); rej != nil || !ok {
				return rej, false
			}
		}
	}

	// The closing delimiter. An error here means malformed input, which Decode
	// reports; either way there is nothing further to walk.
	if _, err := dec.Token(); err != nil {
		return nil, false
	}
	return nil, true
}

func invalid() *Rejection { return &Rejection{CodeInvalidMessage, "V13", false} }
