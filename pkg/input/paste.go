package input

import (
	"strings"

	"golang.org/x/text/unicode/norm"

	"github.com/wottpal/blitzkvm/pkg/protocol/hidrpc"
)

// HID modifier bits used by layout tables.
const (
	modShiftLeft = 0x02
	modAltRight  = 0x40
)

// hidSpace is the HID usage of the space bar, sent after a dead key to emit
// the bare accent character.
const hidSpace = 0x2c

// keyStroke is one key with modifiers.
type keyStroke struct {
	hid      byte
	shift    bool
	altRight bool
}

// charCombo describes how a character is typed on a layout: optionally an
// accent (dead) key first, then the key itself, then — for dead-key
// characters — a space to emit the accent on its own.
type charCombo struct {
	hid      byte
	shift    bool
	altRight bool
	deadKey  bool
	accent   *keyStroke
}

func modifierMask(shift, altRight bool) byte {
	var m byte
	if shift {
		m |= modShiftLeft
	}
	if altRight {
		m |= modAltRight
	}
	return m
}

// PasteStepPressDelay is how long each key is held, matching the upstream web
// UI's executeMacro (20 ms press, then a release step carrying the delay).
const PasteStepPressDelay = 20

// BuildPasteMacro converts text into HID macro steps for the given keyboard
// layout (the layout configured on the target machine). Each keystroke
// becomes a press step (held PasteStepPressDelay ms) and a release step held
// for delay ms, exactly like the upstream web UI. Characters the layout cannot
// type are skipped and returned in invalid (deduplicated, in order).
func BuildPasteMacro(layout, text string, delay uint16) ([]hidrpc.KeyboardMacroStep, []rune) {
	table := generatedLayouts[NormalizeKeyboardLayoutCode(layout)]
	if table == nil {
		table = generatedLayouts["en-US"]
	}
	text = norm.NFC.String(text)
	steps := make([]hidrpc.KeyboardMacroStep, 0, len(text)*2)
	seenInvalid := map[rune]bool{}
	var invalid []rune

	stroke := func(hid, modifier byte) {
		var press hidrpc.KeyboardMacroStep
		press.Modifier = modifier
		press.Keys[0] = hid
		press.Delay = PasteStepPressDelay
		steps = append(steps, press, hidrpc.KeyboardMacroStep{Delay: delay})
	}

	for _, r := range text {
		combo, ok := table[r]
		if !ok {
			if !seenInvalid[r] {
				seenInvalid[r] = true
				invalid = append(invalid, r)
			}
			continue
		}
		if combo.accent != nil {
			stroke(combo.accent.hid, modifierMask(combo.accent.shift, combo.accent.altRight))
		}
		stroke(combo.hid, modifierMask(combo.shift, combo.altRight))
		if combo.deadKey {
			stroke(hidSpace, 0)
		}
	}
	return steps, invalid
}

func InvalidRunesString(invalid []rune) string {
	if len(invalid) == 0 {
		return ""
	}
	parts := make([]string, 0, len(invalid))
	for _, r := range invalid {
		parts = append(parts, string(r))
	}
	return strings.Join(parts, ", ")
}

// LetterKey returns the HID usage of the key that types the lowercase
// letter r on layout, for shortcuts such as ⌘N: the key moves with the
// layout (W is where Z is on AZERTY).
func LetterKey(layout string, r rune) (byte, bool) {
	table := generatedLayouts[NormalizeKeyboardLayoutCode(layout)]
	if table == nil {
		table = generatedLayouts["en-US"]
	}
	combo, ok := table[r]
	if !ok || combo.shift || combo.altRight || combo.deadKey || combo.accent != nil {
		return 0, false
	}
	return combo.hid, true
}
