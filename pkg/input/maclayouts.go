package input

import (
	"sort"

	"github.com/wottpal/blitzkvm/pkg/protocol/hidrpc"
)

// Typing on a Mac. The JetKVM's layout tables follow Windows, and on a Mac
// many characters sit on other keys (on a British Mac Shift-2 types @, a
// French one has - = + elsewhere). macLayouts (maclayouts_gen.go, from the
// layouts macOS ships) say how a Mac whose input source matches the
// JetKVM's layout types a small set of characters: those of clipboard
// sync's installer.

// BuildMacTyping converts text into macro steps (like BuildPasteMacro) for
// a Mac with the input source of layout (macLayoutSources). ok is false
// when there is no table for layout or it can't type a character of text.
func BuildMacTyping(layout, text string, delay uint16) (steps []hidrpc.KeyboardMacroStep, ok bool) {
	table := macLayouts[NormalizeKeyboardLayoutCode(layout)]
	if table == nil {
		return nil, false
	}
	steps = make([]hidrpc.KeyboardMacroStep, 0, 2*len(text))
	for _, r := range text {
		stroke, found := table[r]
		if !found {
			return nil, false
		}
		var press hidrpc.KeyboardMacroStep
		press.Modifier = modifierMask(stroke.shift, stroke.altRight)
		press.Keys[0] = stroke.hid
		press.Delay = PasteStepPressDelay
		steps = append(steps, press, hidrpc.KeyboardMacroStep{Delay: delay})
	}
	return steps, true
}

// MacLetterKey returns the key that types the lowercase letter r on a Mac
// with the input source of layout, for shortcuts such as ⌘N.
func MacLetterKey(layout string, r rune) (byte, bool) {
	stroke, ok := macLayouts[NormalizeKeyboardLayoutCode(layout)][r]
	if !ok || stroke.shift || stroke.altRight {
		return 0, false
	}
	return stroke.hid, true
}

// MacLayoutsTyping lists the layouts whose Mac counterpart types every
// character of charset, sorted.
func MacLayoutsTyping(charset string) []string {
	var out []string
	for layout, table := range macLayouts {
		complete := true
		for _, r := range charset {
			if _, ok := table[r]; !ok {
				complete = false
				break
			}
		}
		if complete {
			out = append(out, layout)
		}
	}
	sort.Strings(out)
	return out
}

// MacInputSource names the Mac input source layout's table assumes ("" if
// none).
func MacInputSource(layout string) string {
	return macLayoutSources[NormalizeKeyboardLayoutCode(layout)]
}
