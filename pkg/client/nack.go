package client

import (
	"math/rand/v2"
	"slices"
	"sync"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtcp"

	"github.com/wottpal/blitzkvm/pkg/video"
)

const (
	// nackMaxPerPacket bounds the NACKs for one missing packet: the first
	// and two repeats a round trip apart, for when a NACK or its
	// retransmission is lost too.
	nackMaxPerPacket = 3
	// nackWindow is how far behind the newest packet a missing one is still
	// asked for, as in pion's generator.
	nackWindow = 512
	// nackMinBudget is the fewest packets one interval may NACK.
	nackMinBudget = 8
)

// nackGenerator asks the device to resend missing video packets (RTCP
// NACK). pion's generator repeats a NACK every interval until the packet
// arrives, and the device resends on every NACK: at a cellular round trip of
// 100-200 ms each loss went out two to six times, on the link that just lost
// it. This one NACKs a missing packet at the next interval, as fast as
// before, and repeats only once a round trip has passed without it
// (video.NACKRetryInterval), at most nackMaxPerPacket times.
//
// The device also resends at once whatever a NACK asks for. After a large
// loss that burst overflows the queue that lost the packets in the first
// place (a DERP relay keeps 32), so an interval asks for no more packets
// than the link delivered in its busiest interval of the last second: the
// retransmissions arrive about as fast as the link drains, oldest first.
type nackGenerator struct {
	interceptor.NoOp
	rtt func() time.Duration

	mu      sync.Mutex
	streams map[uint32]*nackLog
	closed  bool
	close   chan struct{}
	wg      sync.WaitGroup
}

type nackGeneratorFactory struct{ rtt func() time.Duration }

func (f nackGeneratorFactory) NewInterceptor(string) (interceptor.Interceptor, error) {
	return &nackGenerator{rtt: f.rtt, streams: map[uint32]*nackLog{}, close: make(chan struct{})}, nil
}

// BindRTCPWriter starts sending NACKs; pion calls it once per connection.
func (g *nackGenerator) BindRTCPWriter(writer interceptor.RTCPWriter) interceptor.RTCPWriter {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.closed {
		g.wg.Add(1)
		go g.loop(writer)
	}
	return writer
}

// BindRemoteStream watches the sequence numbers of a stream that
// negotiated NACK.
func (g *nackGenerator) BindRemoteStream(info *interceptor.StreamInfo, reader interceptor.RTPReader) interceptor.RTPReader {
	if !slices.ContainsFunc(info.RTCPFeedback, func(fb interceptor.RTCPFeedback) bool { return fb.Type == "nack" && fb.Parameter == "" }) {
		return reader
	}
	log := &nackLog{missing: map[uint16]nackState{}}
	g.mu.Lock()
	g.streams[info.SSRC] = log
	g.mu.Unlock()
	return interceptor.RTPReaderFunc(func(b []byte, a interceptor.Attributes) (int, interceptor.Attributes, error) {
		n, attr, err := reader.Read(b, a)
		if err != nil {
			return 0, nil, err
		}
		if attr == nil {
			attr = make(interceptor.Attributes)
		}
		header, err := attr.GetRTPHeader(b[:n])
		if err != nil {
			return 0, nil, err
		}
		g.mu.Lock()
		log.add(header.SequenceNumber)
		g.mu.Unlock()
		return n, attr, nil
	})
}

func (g *nackGenerator) UnbindRemoteStream(info *interceptor.StreamInfo) {
	g.mu.Lock()
	delete(g.streams, info.SSRC)
	g.mu.Unlock()
}

func (g *nackGenerator) Close() error {
	g.mu.Lock()
	if !g.closed {
		g.closed = true
		close(g.close)
	}
	g.mu.Unlock()
	g.wg.Wait()
	return nil
}

func (g *nackGenerator) loop(writer interceptor.RTCPWriter) {
	defer g.wg.Done()
	sender := rand.Uint32()
	ticker := time.NewTicker(video.NACKInterval)
	defer ticker.Stop()
	for {
		select {
		case <-g.close:
			return
		case now := <-ticker.C:
			retry := video.NACKRetryInterval(g.rtt())
			var nacks []rtcp.Packet
			g.mu.Lock()
			for ssrc, log := range g.streams {
				if seqs := log.due(now, retry); len(seqs) > 0 {
					nacks = append(nacks, &rtcp.TransportLayerNack{SenderSSRC: sender, MediaSSRC: ssrc, Nacks: rtcp.NackPairsFromSequenceNumbers(seqs)})
				}
			}
			g.mu.Unlock()
			if len(nacks) > 0 {
				_, _ = writer.Write(nacks, interceptor.Attributes{})
			}
		}
	}
}

// nackLog tracks the missing packets of one stream.
type nackLog struct {
	started bool
	newest  uint16
	missing map[uint16]nackState
	// arrived counts packets since the last due; delivered keeps that
	// count for the intervals of the last second.
	arrived   int
	delivered [25]int
	interval  int
}

type nackState struct {
	nacks int
	last  time.Time
}

// add notes a received packet: a jump past the newest leaves a gap.
func (l *nackLog) add(seq uint16) {
	l.arrived++
	if !l.started {
		l.started, l.newest = true, seq
		return
	}
	ahead := int16(seq - l.newest)
	if ahead <= 0 {
		delete(l.missing, seq) // a retransmission, or reordered
		return
	}
	for s := seq - uint16(min(int(ahead)-1, nackWindow)); s != seq; s++ {
		l.missing[s] = nackState{}
	}
	l.newest = seq
}

// due runs once an interval and returns the packets to NACK at now, oldest
// first: each missing packet at once, then again whenever retry has passed
// since its last NACK, up to nackMaxPerPacket NACKs, and no more packets
// than arrived in the busiest interval of the last second. It forgets
// packets that fell out of the window or got their last NACK a retry ago.
func (l *nackLog) due(now time.Time, retry time.Duration) []uint16 {
	l.delivered[l.interval%len(l.delivered)] = l.arrived
	l.interval, l.arrived = l.interval+1, 0
	var seqs []uint16
	for s, st := range l.missing {
		waited := now.Sub(st.last) >= retry
		switch {
		case l.newest-s > nackWindow, st.nacks >= nackMaxPerPacket && waited:
			delete(l.missing, s)
		case st.nacks == 0 || (st.nacks < nackMaxPerPacket && waited):
			seqs = append(seqs, s)
		}
	}
	slices.SortFunc(seqs, func(a, b uint16) int { return int(int16(a-l.newest)) - int(int16(b-l.newest)) })
	seqs = seqs[:min(len(seqs), max(slices.Max(l.delivered[:]), nackMinBudget))]
	for _, s := range seqs {
		l.missing[s] = nackState{nacks: l.missing[s].nacks + 1, last: now}
	}
	return seqs
}
