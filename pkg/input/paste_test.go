package input

import "testing"

func TestBuildPasteMacro(t *testing.T) {
	steps, invalid := BuildPasteMacro("en_US", "A!\n", 35)
	if len(invalid) != 0 {
		t.Fatalf("unexpected invalid runes: %v", invalid)
	}
	if len(steps) != 6 {
		t.Fatalf("expected 6 macro steps, got %d", len(steps))
	}
	if steps[0].Modifier != 0x02 || steps[0].Keys[0] != 4 || steps[0].Delay != 20 {
		t.Fatalf("unexpected first step: %+v", steps[0])
	}
	if steps[1].Modifier != 0 || steps[1].Keys[0] != 0 || steps[1].Delay != 35 {
		t.Fatalf("unexpected reset step: %+v", steps[1])
	}
	if steps[2].Modifier != 0x02 || steps[2].Keys[0] != 30 {
		t.Fatalf("unexpected punctuation step: %+v", steps[2])
	}
	if steps[4].Modifier != 0 || steps[4].Keys[0] != 40 {
		t.Fatalf("unexpected enter step: %+v", steps[4])
	}
}

func TestBuildPasteMacroReportsInvalidRunes(t *testing.T) {
	_, invalid := BuildPasteMacro("en_US", "ok€é", 20)
	if len(invalid) != 2 || invalid[0] != '€' || invalid[1] != 'é' {
		t.Fatalf("unexpected invalid runes: %v", invalid)
	}
}

func TestBuildPasteMacroGermanLayout(t *testing.T) {
	// de-DE: '@' is AltGr+Q, 'ä' sits on the Quote key, 'é' is ´ (Equal) then E.
	steps, invalid := BuildPasteMacro("de_DE", "@äé", 20)
	if len(invalid) != 0 {
		t.Fatalf("unexpected invalid runes: %v", invalid)
	}
	type stroke struct{ mod, key byte }
	var got []stroke
	for i := 0; i < len(steps); i += 2 {
		got = append(got, stroke{steps[i].Modifier, steps[i].Keys[0]})
		if steps[i+1].Keys[0] != 0 || steps[i+1].Modifier != 0 {
			t.Fatalf("step %d is not a release: %+v", i+1, steps[i+1])
		}
	}
	want := []stroke{{0x40, 0x14}, {0, 0x34}, {0, 0x2e}, {0, 0x08}}
	if len(got) != len(want) {
		t.Fatalf("strokes = %+v, want %+v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("stroke %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

func TestBuildPasteMacroNormalizesDecomposedInput(t *testing.T) {
	// "a" + COMBINING DIAERESIS must type like the precomposed "ä".
	decomposed, _ := BuildPasteMacro("de-DE", "ä", 20)
	precomposed, _ := BuildPasteMacro("de-DE", "ä", 20)
	if len(decomposed) != len(precomposed) || decomposed[0] != precomposed[0] {
		t.Fatalf("decomposed %+v != precomposed %+v", decomposed, precomposed)
	}
}

func TestEverySupportedLayoutHasATable(t *testing.T) {
	for _, l := range SupportedKeyboardLayouts() {
		if len(generatedLayouts[l.Code]) == 0 {
			t.Fatalf("layout %s has no generated table", l.Code)
		}
	}
}

func TestLetterKeyFollowsTheLayout(t *testing.T) {
	for _, tc := range []struct {
		layout string
		r      rune
		hid    byte
	}{
		{"en-US", 'w', 0x1a},
		{"de-DE", 'z', 0x1c}, // QWERTZ: Z where Y is on QWERTY
		{"fr-FR", 'w', 0x1d}, // AZERTY: W where Z is
		{"", 'n', 0x11},
	} {
		hid, ok := LetterKey(tc.layout, tc.r)
		if !ok || hid != tc.hid {
			t.Errorf("%s %q: %#x %v, want %#x", tc.layout, tc.r, hid, ok, tc.hid)
		}
	}
}
