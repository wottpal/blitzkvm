package input

import (
	"sort"
	"time"
)

type KeyEvent struct {
	HID   byte
	Press bool
}

type Keyboard struct {
	pressed       map[Key]bool
	nextKeepAlive time.Time
}

func NewKeyboard() *Keyboard {
	return &Keyboard{
		pressed: map[Key]bool{},
	}
}

const (
	keyKeepAliveInterval = 50 * time.Millisecond
)

// Update diffs the currently pressed keys against the previous call and
// returns the HID events to send. Releases come before presses, so a key
// released and another pressed within one sample cannot combine (e.g. Shift
// released + "a" pressed must type "a", not "A"). Within presses, modifiers
// go first; within releases, modifiers go last.
func (k *Keyboard) Update(keys []Key, now time.Time) []KeyEvent {
	current := make(map[Key]bool, len(keys))
	for _, key := range keys {
		current[key] = true
	}

	var released, pressed []Key
	for key := range k.pressed {
		if !current[key] {
			released = append(released, key)
		}
	}
	for key := range current {
		if !k.pressed[key] {
			pressed = append(pressed, key)
		}
	}
	sortKeys(released, false)
	sortKeys(pressed, true)

	events := make([]KeyEvent, 0, len(released)+len(pressed))
	for _, key := range released {
		if hid, ok := KeyToHID(key); ok {
			events = append(events, KeyEvent{HID: hid, Press: false})
		}
	}
	for _, key := range pressed {
		if hid, ok := KeyToHID(key); ok {
			events = append(events, KeyEvent{HID: hid, Press: true})
		}
	}

	k.pressed = current
	switch {
	case len(current) == 0:
		k.nextKeepAlive = time.Time{}
	case len(pressed) > 0 || k.nextKeepAlive.IsZero():
		k.nextKeepAlive = now.Add(keyKeepAliveInterval)
	}
	return events
}

// sortKeys orders keys deterministically, with modifiers first or last.
func sortKeys(keys []Key, modifiersFirst bool) {
	sort.Slice(keys, func(i, j int) bool {
		mi, mj := isModifierKey(keys[i]), isModifierKey(keys[j])
		if mi != mj {
			return mi == modifiersFirst
		}
		return keys[i] < keys[j]
	})
}

func isModifierKey(key Key) bool {
	hid, ok := KeyToHID(key)
	return ok && hid >= 0xe0 && hid <= 0xe7
}

func (k *Keyboard) ReleaseAll() []KeyEvent {
	keys := make([]Key, 0, len(k.pressed))
	for key := range k.pressed {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })

	events := make([]KeyEvent, 0, len(keys))
	for _, key := range keys {
		if hid, ok := KeyToHID(key); ok {
			events = append(events, KeyEvent{HID: hid, Press: false})
		}
	}
	k.pressed = map[Key]bool{}
	k.nextKeepAlive = time.Time{}
	return events
}

func (k *Keyboard) KeepAlive(now time.Time) bool {
	if k.nextKeepAlive.IsZero() || now.Before(k.nextKeepAlive) || len(k.pressed) == 0 {
		return false
	}
	for !k.nextKeepAlive.After(now) {
		k.nextKeepAlive = k.nextKeepAlive.Add(keyKeepAliveInterval)
	}
	return true
}

func (k *Keyboard) Pressed() []Key {
	keys := make([]Key, 0, len(k.pressed))
	for key := range k.pressed {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })
	return keys
}
