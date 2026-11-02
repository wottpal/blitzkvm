package engine

import "testing"

func TestCappedBufferKeepsTheStart(t *testing.T) {
	b := &cappedBuffer{max: 5}
	n, err := b.Write([]byte("abc"))
	if n != 3 || err != nil {
		t.Fatal(n, err)
	}
	if n, _ := b.Write([]byte("defgh")); n != 5 {
		t.Fatalf("a capped write reports %d, not all it took", n)
	}
	if b.String() != "abcde" || !b.over {
		t.Fatalf("got %q over=%v", b.String(), b.over)
	}
}
