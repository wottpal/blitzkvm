package emulator

import (
	"testing"
	"time"
)

func TestNetemHoldReleasesAtTheEndOfTheStall(t *testing.T) {
	start := time.Unix(1000, 0)
	n := &netemInterceptor{cfg: NetemConfig{HoldEvery: time.Second, HoldFor: 300 * time.Millisecond}, start: start}
	for _, tc := range []struct{ at, want time.Duration }{
		{0, 0},
		{699 * time.Millisecond, 699 * time.Millisecond},
		{700 * time.Millisecond, time.Second},
		{950 * time.Millisecond, time.Second},
		{1200 * time.Millisecond, 1200 * time.Millisecond},
		{1800 * time.Millisecond, 2 * time.Second},
	} {
		if got := n.due(start.Add(tc.at)).Sub(start); got != tc.want {
			t.Errorf("packet at %s leaves at %s, want %s", tc.at, got, tc.want)
		}
	}
}
