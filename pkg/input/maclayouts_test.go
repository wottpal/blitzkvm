package input

import "testing"

// installerChars mirrors hostlink.InstallerChars (input can't import it).
const installerChars = `abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 !"$%&/()=?+*#'-_.:,;`

// On a German and a U.S. Mac every installer character sits where the
// JetKVM's Windows tables put it: the German one was typed on a real Mac.
func TestMacTablesMatchTheVerifiedLayouts(t *testing.T) {
	for _, layout := range []string{"de-DE", "en-US"} {
		for _, r := range installerChars {
			mac, ok := macLayouts[layout][r]
			win := generatedLayouts[layout][r]
			if !ok || win.deadKey || win.accent != nil || mac != (keyStroke{hid: win.hid, shift: win.shift, altRight: win.altRight}) {
				t.Errorf("%s %q: Mac %+v, Windows %+v", layout, r, mac, win)
			}
		}
	}
}

func TestMacTablesKnowWhereMacsDiffer(t *testing.T) {
	for _, tc := range []struct {
		layout string
		r      rune
		want   keyStroke
	}{
		{"en-UK", '"', keyStroke{hid: 0x34, shift: true}}, // Shift-2 is @ on a British Mac
		{"fr-FR", '-', keyStroke{hid: 0x2e}},              // next to ), not on 6
		{"fr-FR", '1', keyStroke{hid: 0x1e, shift: true}}, // AZERTY digits need Shift
		{"fr-FR", 'w', keyStroke{hid: 0x1d}},              // where QWERTY has Z
		{"de-DE", 'z', keyStroke{hid: 0x1c}},              // where QWERTY has Y
	} {
		if got := macLayouts[tc.layout][tc.r]; got != tc.want {
			t.Errorf("%s %q: %+v, want %+v", tc.layout, tc.r, got, tc.want)
		}
	}
}

// The two keys macOS swaps on ISO keyboards are never used.
func TestMacTablesAvoidTheISOSwappedKeys(t *testing.T) {
	for layout, table := range macLayouts {
		for r, stroke := range table {
			if stroke.hid == 0x35 || stroke.hid == 0x64 {
				t.Errorf("%s %q uses HID %#x", layout, r, stroke.hid)
			}
		}
	}
}

func TestMacLayoutsTypingTheInstaller(t *testing.T) {
	got := MacLayoutsTyping(installerChars)
	want := []string{"cs-CZ", "da-DK", "de-CH", "de-DE", "en-UK", "en-US", "es-ES", "fr-CH", "fr-FR", "it-IT", "nb-NO",
		"nl-BE", "pl-PL", "pt-PT", "sl-SI", "sv-SE"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
}

func TestBuildMacTyping(t *testing.T) {
	steps, ok := BuildMacTyping("fr-FR", "Terminal", 20)
	if !ok || len(steps) != 16 {
		t.Fatalf("%d steps, ok %v", len(steps), ok)
	}
	if steps[0].Keys[0] != 0x17 || steps[0].Modifier != modShiftLeft || steps[1].Keys[0] != 0 || steps[1].Delay != 20 {
		t.Fatalf("T typed as %+v then %+v", steps[0], steps[1])
	}
	if _, ok := BuildMacTyping("fr-FR", "ü", 20); ok {
		t.Fatal("typed a character the table lacks")
	}
	if _, ok := BuildMacTyping("ja-JP", "a", 20); ok {
		t.Fatal("typed on a layout without a Mac table")
	}
	if key, ok := MacLetterKey("fr-FR", 'w'); !ok || key != 0x1d {
		t.Fatalf("⌘W on a French Mac: %#x %v", key, ok)
	}
	if MacInputSource("en-UK") != "com.apple.keylayout.British" {
		t.Fatal(MacInputSource("en-UK"))
	}
}
