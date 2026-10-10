//go:build race

package emulator

// raceEnabled skips timing-sensitive media tests: the race detector slows
// pion's packet path far beyond realistic retransmission deadlines.
const raceEnabled = true
