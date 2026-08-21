package tui

import (
	"context"

	"github.com/roeeyn/skulk/internal/relay"
)

// Session is the slice of internal/relay the TUI uses.
//
// It exists so the model can be driven by tests without a socket. *relay.Session
// satisfies it in production; a fake satisfies it in every test in this package,
// which is what keeps TUI tests fast and deterministic instead of dependent on a
// live relay.
type Session interface {
	Create(ctx context.Context, roomID, password string) (*relay.Info, error)
	Join(ctx context.Context, roomID, password string) (*relay.Info, error)
	Send(ctx context.Context, text string) (string, error)
	Who(ctx context.Context) ([]relay.Participant, error)
	Events() <-chan relay.Event
	Close() error
}

// Dialer opens a session. The second seam: tests hand the model a fake without
// ever resolving a URL.
type Dialer func(ctx context.Context, endpoint string) (Session, error)

// Generator produces a suggested passphrase. The third seam, and the one the A5
// create flow needs: "Enter accepts the generated passphrase" cannot be asserted
// against a value the test does not know.
type Generator func() (string, error)

// DialRelay is the production Dialer.
func DialRelay(ctx context.Context, endpoint string) (Session, error) {
	return relay.Dial(ctx, endpoint)
}

// DialRelayWith is DialRelay carrying session options — today the debug writer
// that §7.2's --debug turns on. A Dialer takes only a context and an endpoint by
// design (it is the seam the tests replace), so anything else has to arrive in a
// closure rather than as another parameter.
func DialRelayWith(opts relay.Options) Dialer {
	return func(ctx context.Context, endpoint string) (Session, error) {
		return relay.DialWithOptions(ctx, endpoint, opts)
	}
}
