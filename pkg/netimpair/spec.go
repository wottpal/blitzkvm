package netimpair

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"
)

// Profiles are typical links, by name. Their numbers are plausible, not
// measured: a good LTE cell; a loaded one with deep buffers and short radio
// outages; a shared hotel Wi-Fi; a path through a Tailscale DERP relay
// (shallow queue that drops the oldest packets).
var Profiles = map[string]string{
	"lte":           "rate=12mbit,queue=300ms,delay=20ms,jitter=4ms,loss=0.1%,burst=2",
	"lte-congested": "rate=4mbit,queue=1.5s,delay=30ms,jitter=10ms,loss=0.5%,burst=3,outage-every=20s,outage=200ms-800ms",
	"wifi-hotel":    "rate=5mbit,queue=200ms,delay=25ms,jitter=8ms,loss=1.5%,burst=4",
	"derp":          "rate=3mbit,queue=32p,drop=head,delay=50ms,jitter=10ms",
}

// Parse reads a path description: a profile name, comma-separated
// key=value settings, or a profile followed by settings that override it
// ("lte,loss=1%"). Keys:
//
//	rate=12mbit          bottleneck (bit, kbit, mbit, gbit per second)
//	trace=<file>         Mahimahi delivery trace instead of a rate
//	queue=300ms|64kb|32p queue limit: the time to drain it at the link's
//	                     rate, bytes (b, kb, mb) or packets
//	drop=tail|head       which packet a full queue drops
//	delay=20ms           one-way propagation delay
//	jitter=4ms           ± delay variation (never reorders)
//	loss=0.1%            mean loss rate (Gilbert–Elliott)
//	burst=2              mean loss burst length in packets
//	outage-every=20s     mean time between outages
//	outage=200ms-800ms   outage duration (or one value)
//	seed=1               reproducible randomness
func Parse(spec string) (Config, error) {
	items := strings.Split(spec, ",")
	if first := strings.TrimSpace(items[0]); !strings.Contains(first, "=") {
		profile, ok := Profiles[first]
		if !ok {
			return Config{}, fmt.Errorf("unknown profile %q", first)
		}
		items = append(strings.Split(profile, ","), items[1:]...)
	}
	var cfg Config
	// A queue given as a time is converted once the rate is known.
	var queueTime time.Duration
	for _, item := range items {
		key, value, ok := strings.Cut(strings.TrimSpace(item), "=")
		if !ok {
			return Config{}, fmt.Errorf("want key=value, got %q", item)
		}
		if err := cfg.set(key, value, &queueTime); err != nil {
			return Config{}, fmt.Errorf("%s: %w", key, err)
		}
	}
	if queueTime > 0 {
		rate := cfg.Rate
		if len(cfg.Trace) > 0 {
			rate = float64(len(cfg.Trace)*MTU*8) / cfg.Trace[len(cfg.Trace)-1].Seconds()
		}
		if rate <= 0 {
			return Config{}, fmt.Errorf("queue=%s needs a rate or trace", queueTime)
		}
		cfg.QueueBytes, cfg.QueuePackets = int(rate*queueTime.Seconds()/8), 0
	}
	return cfg, nil
}

func (cfg *Config) set(key, value string, queueTime *time.Duration) error {
	var err error
	switch key {
	case "rate":
		cfg.Rate, err = parseRate(value)
		cfg.Trace = nil
	case "trace":
		cfg.Trace, err = readTrace(value)
	case "queue":
		*queueTime, cfg.QueueBytes, cfg.QueuePackets, err = parseQueue(value)
	case "drop":
		switch value {
		case "tail", "head":
			cfg.DropHead = value == "head"
		default:
			err = fmt.Errorf("want tail or head, got %q", value)
		}
	case "delay":
		cfg.Delay, err = time.ParseDuration(value)
	case "jitter":
		cfg.Jitter, err = time.ParseDuration(value)
	case "loss":
		cfg.Loss, err = parseFraction(value)
		if err == nil && cfg.Loss >= 1 {
			err = fmt.Errorf("must be below 100%%")
		}
	case "burst":
		cfg.LossBurst, err = strconv.ParseFloat(value, 64)
	case "outage-every":
		cfg.OutageEvery, err = time.ParseDuration(value)
	case "outage":
		lo, hi, _ := strings.Cut(value, "-")
		if cfg.OutageMin, err = time.ParseDuration(lo); err == nil {
			cfg.OutageMax = cfg.OutageMin
			if hi != "" {
				cfg.OutageMax, err = time.ParseDuration(hi)
			}
		}
	case "seed":
		cfg.Seed, err = strconv.ParseUint(value, 10, 64)
	default:
		err = fmt.Errorf("unknown setting")
	}
	return err
}

func parseRate(s string) (float64, error) {
	for _, u := range []struct {
		suffix string
		scale  float64
	}{{"gbit", 1e9}, {"mbit", 1e6}, {"kbit", 1e3}, {"bit", 1}} {
		if n, ok := strings.CutSuffix(s, u.suffix); ok {
			v, err := strconv.ParseFloat(n, 64)
			return v * u.scale, err
		}
	}
	return 0, fmt.Errorf("want a rate like 12mbit, got %q", s)
}

func parseQueue(s string) (d time.Duration, bytes, packets int, err error) {
	if n, ok := strings.CutSuffix(s, "p"); ok {
		packets, err = strconv.Atoi(n)
		return
	}
	for _, u := range []struct {
		suffix string
		scale  int
	}{{"mb", 1e6}, {"kb", 1e3}, {"b", 1}} {
		if n, ok := strings.CutSuffix(s, u.suffix); ok {
			bytes, err = strconv.Atoi(n)
			bytes *= u.scale
			return
		}
	}
	d, err = time.ParseDuration(s)
	return
}

func parseFraction(s string) (float64, error) {
	if n, ok := strings.CutSuffix(s, "%"); ok {
		v, err := strconv.ParseFloat(n, 64)
		return v / 100, err
	}
	return strconv.ParseFloat(s, 64)
}

func readTrace(path string) ([]time.Duration, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return ParseTrace(f)
}

// ParseTrace reads a Mahimahi trace: one delivery opportunity per line, as
// whole milliseconds from the start, ascending. Repeated lines are several
// opportunities at the same moment.
func ParseTrace(r io.Reader) ([]time.Duration, error) {
	var trace []time.Duration
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		ms, err := strconv.ParseUint(line, 10, 32)
		if err != nil {
			return nil, fmt.Errorf("trace line %q: %w", line, err)
		}
		at := time.Duration(ms) * time.Millisecond
		if len(trace) > 0 && at < trace[len(trace)-1] {
			return nil, fmt.Errorf("trace goes back in time at %s", at)
		}
		trace = append(trace, at)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(trace) == 0 || trace[len(trace)-1] <= 0 {
		return nil, fmt.Errorf("trace must end after 0 ms")
	}
	return trace, nil
}
