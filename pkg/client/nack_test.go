package client

import (
	"slices"
	"testing"
	"time"

	"github.com/wottpal/blitzkvm/pkg/video"
)

func newNACKLog(seqs ...uint16) *nackLog {
	l := &nackLog{missing: map[uint16]nackState{}}
	for _, s := range seqs {
		l.add(s)
	}
	return l
}

// nackRounds runs the generator's 40 ms ticks for d and returns the
// sequence numbers NACKed at each tick that sent any.
func nackRounds(l *nackLog, start time.Time, d, retry time.Duration) map[time.Duration][]uint16 {
	sent := map[time.Duration][]uint16{}
	for at := time.Duration(0); at <= d; at += video.NACKInterval {
		if seqs := l.due(start.Add(at), retry); len(seqs) > 0 {
			sent[at] = seqs
		}
	}
	return sent
}

func TestNACKRepeatsARoundTripApartAtMostThreeTimes(t *testing.T) {
	start := time.Unix(100, 0)
	l := newNACKLog(10, 13) // 11 and 12 missing
	retry := video.NACKRetryInterval(150 * time.Millisecond)
	if retry != 197500*time.Microsecond {
		t.Fatalf("retry after %s, want 1.25 × RTT + 10 ms", retry)
	}
	sent := nackRounds(l, start, time.Second, retry)
	// At once, then on the first tick at least 197.5 ms later, twice.
	want := map[time.Duration][]uint16{0: {11, 12}, 200 * time.Millisecond: {11, 12}, 400 * time.Millisecond: {11, 12}}
	if len(sent) != len(want) {
		t.Fatalf("NACKs %v, want %v", sent, want)
	}
	for at, seqs := range want {
		if !slices.Equal(sent[at], seqs) {
			t.Fatalf("NACKs %v, want %v", sent, want)
		}
	}
	if len(l.missing) != 0 {
		t.Fatalf("still tracking %v after the last NACK", l.missing)
	}
}

func TestNACKOnALANRepeatsEveryInterval(t *testing.T) {
	start := time.Unix(100, 0)
	l := newNACKLog(10, 12)
	sent := nackRounds(l, start, time.Second, video.NACKRetryInterval(time.Millisecond))
	if len(sent) != 3 || sent[0] == nil || sent[40*time.Millisecond] == nil || sent[80*time.Millisecond] == nil {
		t.Fatalf("NACKs %v, want one per 40 ms tick, three in all", sent)
	}
}

func TestNACKStopsWhenRepaired(t *testing.T) {
	start := time.Unix(100, 0)
	l := newNACKLog(10, 13)
	retry := video.NACKRetryInterval(100 * time.Millisecond)
	if seqs := l.due(start, retry); !slices.Equal(seqs, []uint16{11, 12}) {
		t.Fatalf("first NACK %v", seqs)
	}
	l.add(11) // retransmission
	if seqs := l.due(start.Add(time.Second), retry); !slices.Equal(seqs, []uint16{12}) {
		t.Fatalf("repeat %v, want only the packet still missing", seqs)
	}
}

func TestNACKAcrossWrapAndWindow(t *testing.T) {
	start := time.Unix(100, 0)
	l := newNACKLog(65533, 1)
	if seqs := l.due(start, time.Second); !slices.Equal(seqs, []uint16{65534, 65535, 0}) {
		t.Fatalf("NACKs across the wrap %v", seqs)
	}
	l = newNACKLog(0, 2000)
	l.arrived = 1000 // a fast link
	if seqs := l.due(start, time.Second); len(seqs) != nackWindow || seqs[0] != 2000-nackWindow {
		t.Fatalf("NACKed %d packets from %d, want the last %d", len(seqs), seqs[0], nackWindow)
	}
	l.add(2000 + nackWindow)
	if seqs := l.due(start.Add(2*time.Second), time.Second); len(seqs) != nackWindow-1 {
		t.Fatalf("NACKed %d packets after the window moved", len(seqs))
	}
}

func TestNACKAsksNoFasterThanTheLinkDelivers(t *testing.T) {
	start := time.Unix(100, 0)
	l := newNACKLog(0, 101) // a burst of 100 lost
	for s := uint16(102); s < 122; s++ {
		l.add(s) // 20 delivered this interval, as through a slow link's queue
	}
	retry := video.NACKRetryInterval(100 * time.Millisecond)
	first := l.due(start, retry)
	if len(first) != 22 || first[0] != 1 || first[21] != 22 {
		t.Fatalf("first interval NACKed %d from %d, want the oldest 22 (as many as arrived)", len(first), first[0])
	}
	// Quiet intervals keep the busiest of the last second.
	if next := l.due(start.Add(video.NACKInterval), retry); len(next) != 22 || next[0] != 23 {
		t.Fatalf("second interval NACKed %d from %d, want the next 22", len(next), next[0])
	}
	for i := range 26 { // a quiet second
		l.due(start.Add(time.Duration(i+2)*video.NACKInterval), retry)
	}
	l.add(300) // another burst lost
	if got := l.due(start.Add(30*video.NACKInterval), retry); len(got) != nackMinBudget || got[0] != 122 {
		t.Fatalf("after a quiet second NACKed %d, want the oldest %d", len(got), nackMinBudget)
	}
}
