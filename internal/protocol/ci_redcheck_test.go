package protocol_test

import "testing"

// TEMPORARY — ROJ-37 acceptance criterion: "a deliberately broken test on a branch
// turns the PR red (verify once, then revert)". This commit is reverted immediately
// after CI shows red. Note the name has no TestPendingCodec_ prefix, so it lands
// inside the green gate rather than the expected-red one.
func TestCIRedCheck(t *testing.T) {
	t.Fatal("deliberate failure: proving the client job's green gate is load-bearing")
}
