package client

import (
	"sync"
	"time"
)

// pointerInterval is how often absolute pointer moves go out off a LAN: the
// device encodes at most 60 frames a second, so more moves show no more
// positions (a held one may make a frame later, 8 ms on average), while each
// report costs the JetKVM's single core a packet in and the work behind it.
// With Tailscale on the device, a pointer moved 100 times a second took its
// app and tailscaled from 16 % to 41 % of its CPU at 60 a second (71 % at
// 100), which delays the picture.
const pointerInterval = time.Second / 60

// pointerReport is one absolute pointer report and the channel it takes.
type pointerReport struct {
	x, y     int32
	buttons  byte
	reliable bool
}

// pointerPacer sends absolute pointer reports. While pacing is on, a move
// within interval of the last report waits, and only the newest waiting move
// goes out once the interval has passed. A button change goes at once, after
// a waiting move (a drag's last stretch keeps its button). Sends are
// serialized, so a waiting move can never follow a newer report.
type pointerPacer struct {
	interval time.Duration
	send     func(pointerReport) error

	mu      sync.Mutex
	pacing  bool
	sentAt  time.Time
	pending *pointerReport
	timer   *time.Timer
}

func newPointerPacer(send func(pointerReport) error) *pointerPacer {
	return &pointerPacer{interval: pointerInterval, send: send}
}

// setPacing turns pacing on (off a LAN) or off.
func (p *pointerPacer) setPacing(on bool) {
	p.mu.Lock()
	p.pacing = on
	p.mu.Unlock()
}

// report sends r now or, while pacing, once the interval since the last
// report has passed. change marks a button change (or the first report
// after the handshake), which never waits.
func (p *pointerPacer) report(r pointerReport, change bool) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	if wait := p.sentAt.Add(p.interval).Sub(now); p.pacing && !change && wait > 0 {
		p.pending = &r
		if p.timer == nil {
			p.timer = time.AfterFunc(wait, p.flush)
		}
		return nil
	}
	if pending := p.pending; pending != nil {
		p.pending = nil
		_ = p.send(*pending)
	}
	p.sentAt = now
	return p.send(r)
}

// flush sends the waiting move now, if any: when its timer fires, and before
// a report on another channel (wheel, relative mouse) that must not overtake
// it.
func (p *pointerPacer) flush() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.timer != nil {
		p.timer.Stop()
		p.timer = nil
	}
	if r := p.pending; r != nil {
		p.pending = nil
		p.sentAt = time.Now()
		_ = p.send(*r)
	}
}

// stop drops a waiting move.
func (p *pointerPacer) stop() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.pending = nil
	if p.timer != nil {
		p.timer.Stop()
		p.timer = nil
	}
}
