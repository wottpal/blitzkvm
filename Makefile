.PHONY: build engine emulator test test-race test-timing vet vulncheck generate generate-check layouts maclayouts check app

GO ?= go

build:
	$(GO) build ./...

# Helper process used by the native macOS app (one process per device session).
engine:
	$(GO) build -trimpath -o bin/blitzkvm-engine ./cmd/blitzkvm-engine

# Local fake JetKVM for manual testing: `make emulator` then connect to http://127.0.0.1:8080
emulator:
	$(GO) run ./test/emulator-serve

test:
	$(GO) test -count=1 -p 1 ./...
	cd third_party/openh264-go && $(GO) test -count=1 ./...

test-race:
	$(GO) test -race -count=1 -p 1 ./...

# Timing-sensitive tests skip themselves under the race detector.
test-timing:
	$(GO) test -count=1 -run 'TestPacketLossIsRepairedByNACK|TestNACKRepairAtLongRoundTrips' ./pkg/emulator

vet:
	$(GO) vet ./...

vulncheck:
	$(GO) run golang.org/x/vuln/cmd/govulncheck@latest ./...

generate:
	$(GO) generate ./...

# Fails if generated code is out of date (or the tree has other changes).
generate-check: generate
	git diff --exit-code

# Regenerate keyboard layout tables from a jetkvm/kvm checkout:
#   make layouts UPSTREAM=../kvm
layouts:
	@test -n "$(UPSTREAM)" || { echo "usage: make layouts UPSTREAM=../kvm" >&2; exit 2; }
	$(GO) run ./scripts/genlayouts -upstream $(UPSTREAM) -ref "$$(git -C $(UPSTREAM) describe --always --tags)" > pkg/input/layouts_gen.go.tmp
	mv pkg/input/layouts_gen.go.tmp pkg/input/layouts_gen.go

# Regenerate how a Mac types clipboard sync's installer on each layout, from
# the keyboard layouts of the macOS this runs on:
#   make maclayouts
maclayouts:
	swift scripts/genmaclayouts.swift | gofmt > pkg/input/maclayouts_gen.go.tmp
	mv pkg/input/maclayouts_gen.go.tmp pkg/input/maclayouts_gen.go

# The same steps as .github/workflows/fork-check.yml.
check: vet generate-check test-race test-timing vulncheck
	cd third_party/openh264-go && $(GO) test -count=1 ./...
	$(MAKE) -C macos test

# Native macOS app (builds the Go engine helper and bundles it).
app:
	$(MAKE) -C macos app
