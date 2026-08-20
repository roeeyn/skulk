package protocol_test

// Contract test for the protocol v0 golden frame corpus (ticket ROJ-29, milestone M0).
//
// This is the Go half of the cross-language schema contract described in design
// amendment A13: the Go client and the Elixir relay implement independent codecs
// and must accept/reject every vector in docs/protocol/corpus/ identically, with
// identical error codes. The Elixir half is skulkd/test/protocol_contract_test.exs.
//
// STATE AT THE END OF ROJ-29: TestCorpusIntegrity passes; the two codec tests
// fail, because internal/protocol has no codec yet — that is ROJ-33 (M0-5).
// The failure is deliberate and is this ticket's deliverable. To turn it green,
// ROJ-33 replaces the body of newValidator (and nothing else in this file) with
// an adapter over the real codec.

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// corpusDir is relative to this package directory: `go test` sets the working
// directory to the package under test.
const corpusDir = "../../docs/protocol/corpus"

// ---------------------------------------------------------------------------
// The seam
// ---------------------------------------------------------------------------

type role string

const (
	roleRelay  role = "relay"
	roleClient role = "client"
)

type frameKind string

const (
	kindText   frameKind = "text"
	kindBinary frameKind = "binary"
)

// validateFn is the contract every skulk protocol v0 codec must satisfy
// (docs/protocol-v0.md §7.3). It validates one received WebSocket frame as the
// given receiving peer and returns the protocol v0 error code the receiver must
// answer with, or "" when the frame is valid.
//
// It is parameterized by receiver role, and it covers every type in the registry
// in BOTH roles — the relay never legitimately receives a chat.message, but it
// must still reject one as a direction violation.
type validateFn func(receiver role, kind frameKind, frame []byte) (errorCode string)

// newValidator returns the codec under test.
//
// ROJ-33 (M0-5) implements internal/protocol and replaces this body with an
// adapter, e.g.:
//
//	return func(receiver role, kind frameKind, frame []byte) string {
//		return protocol.Validate(protocol.Role(receiver), protocol.Kind(kind), frame)
//	}
func newValidator(t *testing.T) validateFn {
	t.Helper()
	t.Fatalf("protocol v0 codec is not implemented yet.\n"+
		"  This failure is expected and is ROJ-29's deliverable: the corpus and both\n"+
		"  contract harnesses exist before any codec does.\n"+
		"  Implement it in ROJ-33 (M0-5) against %s, then replace newValidator in %s.\n"+
		"  Corpus integrity is checked separately by TestCorpusIntegrity, which passes —\n"+
		"  so a red run here means a missing codec, not a broken harness.",
		"docs/protocol-v0.md", "internal/protocol/protocol_test.go")
	return nil
}

// ---------------------------------------------------------------------------
// Corpus model
// ---------------------------------------------------------------------------

type registry struct {
	ProtocolVersion int    `json:"protocol_version"`
	CorpusVersion   int    `json:"corpus_version"`
	Spec            string `json:"spec"`
	FrameTypes      []struct {
		Type       string   `json:"type"`
		Directions []string `json:"directions"`
	} `json:"frame_types"`
	ErrorCodes      []string         `json:"error_codes"`
	ValidationRules []string         `json:"validation_rules"`
	Limits          map[string]int64 `json:"limits"`
}

type expectation struct {
	Result    string `json:"result"`
	ErrorCode string `json:"error_code"`
	Rule      string `json:"rule"`
	Close     bool   `json:"close"`
}

type wireSpec struct {
	Kind   string          `json:"kind"`
	JSON   json.RawMessage `json:"json"`
	Raw    *string         `json:"raw"`
	Base64 *string         `json:"base64"`
}

type vector struct {
	Name        string      `json:"name"`
	Description string      `json:"description"`
	FrameType   *string     `json:"frame_type"`
	Direction   string      `json:"direction"`
	Receiver    string      `json:"receiver"`
	Expect      expectation `json:"expect"`
	Wire        wireSpec    `json:"wire"`
	Notes       string      `json:"notes"`

	path string
}

// bytes reconstructs the exact frame bytes this vector describes
// (docs/protocol/corpus/README.md, "wire").
func (v vector) bytes() ([]byte, error) {
	set := 0
	if len(v.Wire.JSON) > 0 {
		set++
	}
	if v.Wire.Raw != nil {
		set++
	}
	if v.Wire.Base64 != nil {
		set++
	}
	if set != 1 {
		return nil, fmt.Errorf("wire must set exactly one of json/raw/base64, got %d", set)
	}

	switch {
	case len(v.Wire.JSON) > 0:
		// Re-serialize compactly so both languages feed the codec equivalent
		// bytes. Vectors whose byte LENGTH is under test use raw instead.
		compacted, err := compactJSON(v.Wire.JSON)
		if err != nil {
			return nil, fmt.Errorf("wire.json is not valid JSON: %w", err)
		}
		return compacted, nil
	case v.Wire.Raw != nil:
		return []byte(*v.Wire.Raw), nil
	default:
		b, err := base64.StdEncoding.DecodeString(*v.Wire.Base64)
		if err != nil {
			return nil, fmt.Errorf("wire.base64 is not valid base64: %w", err)
		}
		return b, nil
	}
}

func (v vector) kind() frameKind { return frameKind(v.Wire.Kind) }

func (v vector) role() role {
	if v.Receiver == string(roleRelay) {
		return roleRelay
	}
	return roleClient
}

func compactJSON(raw json.RawMessage) ([]byte, error) {
	var buf bytes.Buffer
	if err := json.Compact(&buf, raw); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

type corpus struct {
	registry registry
	valid    []vector
	invalid  []vector
}

func loadCorpus(t *testing.T) corpus {
	t.Helper()

	var c corpus
	raw, err := os.ReadFile(filepath.Join(corpusDir, "registry.json"))
	if err != nil {
		t.Fatalf("reading corpus registry: %v", err)
	}
	if err := json.Unmarshal(raw, &c.registry); err != nil {
		t.Fatalf("parsing corpus registry: %v", err)
	}
	c.valid = loadVectors(t, filepath.Join(corpusDir, "valid"))
	c.invalid = loadVectors(t, filepath.Join(corpusDir, "invalid"))
	return c
}

func loadVectors(t *testing.T, dir string) []vector {
	t.Helper()

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("reading corpus directory %s: %v", dir, err)
	}

	var vectors []vector
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		path := filepath.Join(dir, e.Name())
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("reading vector %s: %v", path, err)
		}
		var v vector
		dec := json.NewDecoder(strings.NewReader(string(raw)))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&v); err != nil {
			t.Fatalf("parsing vector %s: %v", path, err)
		}
		v.path = path
		vectors = append(vectors, v)
	}
	sort.Slice(vectors, func(i, j int) bool { return vectors[i].Name < vectors[j].Name })

	if len(vectors) == 0 {
		t.Fatalf("no vectors found in %s", dir)
	}
	return vectors
}

// ---------------------------------------------------------------------------
// Pass 1 — corpus integrity. Passes today, and must keep passing: it is what
// makes the codec failures below trustworthy.
// ---------------------------------------------------------------------------

func TestCorpusIntegrity(t *testing.T) {
	c := loadCorpus(t)

	if c.registry.ProtocolVersion != 0 {
		t.Errorf("registry protocol_version = %d, want 0", c.registry.ProtocolVersion)
	}

	codes := setOf(c.registry.ErrorCodes)
	rules := setOf(c.registry.ValidationRules)
	directions := map[string][]string{}
	for _, ft := range c.registry.FrameTypes {
		directions[ft.Type] = ft.Directions
	}

	check := func(v vector, wantResult string) {
		t.Run(filepath.Base(filepath.Dir(v.path))+"/"+v.Name, func(t *testing.T) {
			if got := strings.TrimSuffix(filepath.Base(v.path), ".json"); got != v.Name {
				t.Errorf("name %q does not match filename %q", v.Name, got)
			}
			if v.Description == "" {
				t.Error("description is empty")
			}
			if v.Direction != "c2r" && v.Direction != "r2c" {
				t.Errorf("direction %q is neither c2r nor r2c", v.Direction)
			}
			wantReceiver := string(roleRelay)
			if v.Direction == "r2c" {
				wantReceiver = string(roleClient)
			}
			if v.Receiver != wantReceiver {
				t.Errorf("receiver %q contradicts direction %q (want %q)", v.Receiver, v.Direction, wantReceiver)
			}
			if v.Expect.Result != wantResult {
				t.Errorf("expect.result = %q, want %q for a vector in this directory", v.Expect.Result, wantResult)
			}
			if v.Wire.Kind != string(kindText) && v.Wire.Kind != string(kindBinary) {
				t.Errorf("wire.kind %q is neither text nor binary", v.Wire.Kind)
			}
			if v.Wire.Kind == string(kindBinary) && v.Wire.Base64 == nil {
				t.Error("wire.kind is binary but wire.base64 is absent")
			}
			if _, err := v.bytes(); err != nil {
				t.Errorf("wire bytes cannot be reconstructed: %v", err)
			}

			switch wantResult {
			case "accept":
				if v.Expect.ErrorCode != "" || v.Expect.Rule != "" {
					t.Error("a valid vector must not annotate error_code or rule")
				}
				if v.FrameType == nil {
					t.Fatal("a valid vector must name its frame_type")
				}
				dirs, ok := directions[*v.FrameType]
				if !ok {
					t.Fatalf("frame_type %q is not in registry.json", *v.FrameType)
				}
				if !contains(dirs, v.Direction) {
					t.Errorf("frame_type %q does not travel %s per registry.json", *v.FrameType, v.Direction)
				}
			case "reject":
				if !codes[v.Expect.ErrorCode] {
					t.Errorf("expect.error_code %q is not in registry.json", v.Expect.ErrorCode)
				}
				if !rules[v.Expect.Rule] {
					t.Errorf("expect.rule %q is not in registry.json", v.Expect.Rule)
				}
				if v.FrameType != nil {
					if _, ok := directions[*v.FrameType]; !ok {
						t.Errorf("frame_type %q is not in registry.json (use null for frames too broken to have one)", *v.FrameType)
					}
				}
			}
		})
	}

	for _, v := range c.valid {
		check(v, "accept")
	}
	for _, v := range c.invalid {
		check(v, "reject")
	}

	t.Run("every registry type and direction has a valid vector", func(t *testing.T) {
		covered := map[string]bool{}
		for _, v := range c.valid {
			if v.FrameType != nil {
				covered[*v.FrameType+" "+v.Direction] = true
			}
		}
		for _, ft := range c.registry.FrameTypes {
			for _, d := range ft.Directions {
				if !covered[ft.Type+" "+d] {
					t.Errorf("no valid vector for %s %s", ft.Type, d)
				}
			}
		}
	})

	t.Run("every validation rule has an invalid vector", func(t *testing.T) {
		covered := map[string]bool{}
		for _, v := range c.invalid {
			covered[v.Expect.Rule] = true
		}
		for _, r := range c.registry.ValidationRules {
			if !covered[r] {
				t.Errorf("no invalid vector exercises rule %s", r)
			}
		}
	})

	// ROJ-29 acceptance criteria, checked mechanically so they cannot rot.
	t.Run("acceptance criteria", func(t *testing.T) {
		if len(c.invalid) < 10 {
			t.Errorf("corpus has %d invalid vectors, ticket requires at least 10", len(c.invalid))
		}
		if len(c.registry.ErrorCodes) != 10 {
			t.Errorf("registry lists %d error codes, protocol v0 defines exactly 10", len(c.registry.ErrorCodes))
		}
		if len(c.registry.FrameTypes) != 13 {
			t.Errorf("registry lists %d frame types, protocol v0 defines exactly 13", len(c.registry.FrameTypes))
		}
	})
}

// ---------------------------------------------------------------------------
// Pass 2 and 3 — the codec contract. Both fail until ROJ-33 lands.
//
// The TestPendingCodec_ prefix is the Go half of the "red by design" convention.
// CI gates on `go test ./... -skip '^TestPendingCodec'` (must be green) and
// separately asserts these are still failing — so the day the codec lands, CI
// fails until the prefix and that CI step are removed together. Plain
// `go test ./...` stays red on purpose: the red IS the spec.
// ---------------------------------------------------------------------------

func TestPendingCodec_ValidVectorsAreAccepted(t *testing.T) {
	c := loadCorpus(t)
	validate := newValidator(t)

	for _, v := range c.valid {
		t.Run(v.Name, func(t *testing.T) {
			frame, err := v.bytes()
			if err != nil {
				t.Fatalf("reconstructing frame: %v", err)
			}
			if code := validate(v.role(), v.kind(), frame); code != "" {
				t.Errorf("frame rejected with %q, must be accepted\n  %s\n  %s",
					code, v.Description, v.path)
			}
		})
	}
}

func TestPendingCodec_InvalidVectorsAreRejectedWithTheAnnotatedCode(t *testing.T) {
	c := loadCorpus(t)
	validate := newValidator(t)

	for _, v := range c.invalid {
		t.Run(v.Name, func(t *testing.T) {
			frame, err := v.bytes()
			if err != nil {
				t.Fatalf("reconstructing frame: %v", err)
			}
			code := validate(v.role(), v.kind(), frame)
			if code == "" {
				t.Fatalf("frame accepted, must be rejected with %q (rule %s)\n  %s\n  %s",
					v.Expect.ErrorCode, v.Expect.Rule, v.Description, v.path)
			}
			// Exact equality, not mere rejection: identical codes across the two
			// languages ARE the contract (A13).
			if code != v.Expect.ErrorCode {
				t.Errorf("rejected with %q, want %q (rule %s)\n  %s\n  %s",
					code, v.Expect.ErrorCode, v.Expect.Rule, v.Description, v.path)
			}
		})
	}
}

// ---------------------------------------------------------------------------

func setOf(values []string) map[string]bool {
	set := make(map[string]bool, len(values))
	for _, v := range values {
		set[v] = true
	}
	return set
}

func contains(values []string, want string) bool {
	for _, v := range values {
		if v == want {
			return true
		}
	}
	return false
}
