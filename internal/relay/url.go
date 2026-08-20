package relay

import (
	"fmt"
	"net"
	"net/url"
	"strings"
)

// ResolveServer applies spec §7.2's server-selection precedence: the --server flag,
// then SKULK_SERVER, then nothing.
//
// There is deliberately no third fallback. Amendment A10 removed the build-time
// default public relay: shipping one would mean advertising an unauthenticated,
// unthrottled relay (§19 defers rate limiting) next to a one-liner installer.
// Shipping none means --server is required, and that is the trade taken.
func ResolveServer(flagValue, envValue string) (string, error) {
	switch {
	case flagValue != "":
		return flagValue, nil
	case envValue != "":
		return envValue, nil
	default:
		return "", fmt.Errorf("no relay configured: pass --server or set SKULK_SERVER (skulk ships no default relay)")
	}
}

// CheckServerURL enforces spec §7.2's transport policy.
//
// wss:// is always fine. Plain ws:// is refused unless the host is a loopback
// address or the user explicitly passed --allow-insecure — because at M0 the room
// password crosses this connection in the clear inside the frame, and TLS is the
// only thing protecting it (protocol v0 §8).
func CheckServerURL(raw string, allowInsecure bool) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("invalid relay URL %q: %w", raw, err)
	}

	switch u.Scheme {
	case "wss":
		return u, nil
	case "ws":
		if allowInsecure || isLoopback(u.Hostname()) {
			return u, nil
		}
		return nil, fmt.Errorf("refusing ws:// to non-loopback host %q: the room password crosses this connection in the clear. Use wss://, or pass --allow-insecure if you mean it", u.Hostname())
	case "":
		return nil, fmt.Errorf("relay URL %q has no scheme: use wss://host/v1/ws", raw)
	default:
		return nil, fmt.Errorf("relay URL scheme %q is not supported: use wss:// (or ws:// for loopback)", u.Scheme)
	}
}

func isLoopback(host string) bool {
	if host == "localhost" || strings.HasSuffix(host, ".localhost") {
		return true
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback()
	}
	return false
}
