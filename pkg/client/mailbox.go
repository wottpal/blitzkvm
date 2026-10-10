package client

import (
	"sync"
	"time"
)

// mailbox is an unbounded FIFO that never drops while open: producers (pion
// callbacks) must not block, and consumers must not miss lifecycle events
// such as otherSessionConnected or willReboot.
type mailbox[T any] struct {
	mu        sync.Mutex
	queue     []T
	out       chan T
	notify    chan struct{}
	closed    bool
	stopped   chan struct{}
	closeOnce sync.Once
}

// drainGrace is how long a closed mailbox waits for a consumer per remaining
// value before dropping the rest, so its goroutine cannot leak.
const drainGrace = 5 * time.Second

func newMailbox[T any]() *mailbox[T] {
	m := &mailbox[T]{out: make(chan T), notify: make(chan struct{}, 1), stopped: make(chan struct{})}
	go m.run()
	return m
}

func (m *mailbox[T]) put(v T) {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return
	}
	m.queue = append(m.queue, v)
	m.mu.Unlock()
	select {
	case m.notify <- struct{}{}:
	default:
	}
}

// close stops accepting values. Queued values are still delivered (each
// within drainGrace); the output channel is closed afterwards.
func (m *mailbox[T]) close() {
	m.closeOnce.Do(func() {
		m.mu.Lock()
		m.closed = true
		m.mu.Unlock()
		close(m.stopped)
	})
}

func (m *mailbox[T]) run() {
	defer close(m.out)
	for {
		m.mu.Lock()
		if len(m.queue) == 0 {
			closed := m.closed
			m.mu.Unlock()
			if closed {
				return
			}
			select {
			case <-m.notify:
			case <-m.stopped:
			}
			continue
		}
		v := m.queue[0]
		var zero T
		m.queue[0] = zero
		m.queue = m.queue[1:]
		m.mu.Unlock()

		select {
		case m.out <- v:
			continue
		case <-m.stopped:
		}
		select {
		case m.out <- v:
		case <-time.After(drainGrace):
			return
		}
	}
}
