package headless

import "testing"

// Spec §17 groups server_capacity with room_full on exit code 6, and the headless
// contract (docs/headless-v1.md §7) publishes that table to agents.
//
// ROJ-39's ticket said exitFor "already handled" this — it did not, and a code
// that fell through to 1 would have told every agent "unknown failure" for a
// condition they are supposed to be able to retry.
func TestCapacityCodesExitSix(t *testing.T) {
	for _, code := range []string{"room_full", "server_capacity"} {
		if got := exitFor(code); got != ExitCapacity {
			t.Errorf("exitFor(%q) = %d, want %d", code, got, ExitCapacity)
		}
	}
}
