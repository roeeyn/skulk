// Package protocol defines the skulk wire frames (protocol v0 for milestone
// M0). The golden frame corpus under docs/protocol/corpus/ is the contract:
// this package and the Elixir relay (skulkd) must accept/reject every vector
// identically, enforced by contract tests on both sides (design A13).
package protocol

// Version is the wire protocol version sent in every frame's "v" field.
const Version = 0
