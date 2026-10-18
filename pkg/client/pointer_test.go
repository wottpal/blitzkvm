package client

import (
	"slices"
	"sync"
	"testing"
	"time"
)

// sentPointers records what a pacer sends.
type sentPointers struct {
	mu   sync.Mutex
	sent []pointerReport
}

func (s *sentPointers) send(r pointerReport) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sent = append(s.sent, r)
	return nil
}

func (s *sentPointers) get() []pointerReport {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.sent)
}

func pacerForTest(pacing bool) (*pointerPacer, *sentPointers) {
	s := &sentPointers{}
	p := newPointerPacer(s.send)
	p.interval = 40 * time.Millisecond
	p.setPacing(pacing)
	return p, s
}

func move(x int32) pointerReport { return pointerReport{x: x, y: x} }

func TestPointerPacerOffSendsEveryReport(t *testing.T) {
	p, s := pacerForTest(false)
	for x := range int32(5) {
		_ = p.report(move(x), false)
	}
	if got := s.get(); len(got) != 5 {
		t.Fatalf("sent %d of 5 reports: %v", len(got), got)
	}
}

// A burst of moves: the first goes at once, the newest when the interval
// has passed, none in between.
func TestPointerPacerSendsTheNewestMoveOncePerInterval(t *testing.T) {
	p, s := pacerForTest(true)
	for x := range int32(10) {
		_ = p.report(move(x), false)
	}
	if got := s.get(); !slices.Equal(got, []pointerReport{move(0)}) {
		t.Fatalf("at once: %v, want only the first move", got)
	}
	time.Sleep(3 * p.interval)
	if got := s.get(); !slices.Equal(got, []pointerReport{move(0), move(9)}) {
		t.Fatalf("after the interval: %v, want the first and the newest move", got)
	}
	// A move long after the last report goes at once again.
	_ = p.report(move(20), false)
	if got := s.get(); len(got) != 3 || got[2] != move(20) {
		t.Fatalf("a move after a pause waited: %v", got)
	}
}

// A button change never waits; a move waiting before it goes first, and
// never after it (a held button after its release).
func TestPointerPacerButtonChangesGoAtOnceAfterAWaitingMove(t *testing.T) {
	p, s := pacerForTest(true)
	press := pointerReport{x: 1, y: 1, buttons: 1, reliable: true}
	drag := pointerReport{x: 2, y: 2, buttons: 1, reliable: true}
	release := pointerReport{x: 3, y: 3, buttons: 0, reliable: true}
	_ = p.report(press, true)
	_ = p.report(drag, false) // waits
	_ = p.report(release, true)
	time.Sleep(3 * p.interval)
	if got := s.get(); !slices.Equal(got, []pointerReport{press, drag, release}) {
		t.Fatalf("sent %v, want the press, the drag, then the release", got)
	}
}

// A report on another channel first sends a waiting move.
func TestPointerPacerFlushSendsAWaitingMoveNow(t *testing.T) {
	p, s := pacerForTest(true)
	_ = p.report(move(1), false)
	_ = p.report(move(2), false)
	p.flush()
	if got := s.get(); !slices.Equal(got, []pointerReport{move(1), move(2)}) {
		t.Fatalf("sent %v after a flush", got)
	}
	time.Sleep(3 * p.interval)
	if got := s.get(); len(got) != 2 {
		t.Fatalf("the timer sent again: %v", got)
	}
}

func TestPointerPacerStopDropsAWaitingMove(t *testing.T) {
	p, s := pacerForTest(true)
	_ = p.report(move(1), false)
	_ = p.report(move(2), false)
	p.stop()
	time.Sleep(3 * p.interval)
	if got := s.get(); len(got) != 1 {
		t.Fatalf("sent %v after stop", got)
	}
}
