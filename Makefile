.PHONY: build engine emulator test test-race vet vulncheck generate check app

GO ?= go

build:
	$(GO) build ./...

# Helper process used by the native macOS app (one process per device session).
engine:
	$(GO) build -trimpath -o bin/jetkvm-engine ./cmd/jetkvm-engine

# Local fake JetKVM for manual testing: `make emulator` then connect to http://127.0.0.1:8080
emulator:
	$(GO) run ./test/emulator-serve

test:
	$(GO) test -count=1 -p 1 ./...
	cd third_party/openh264-go && $(GO) test -count=1 ./...

test-race:
	$(GO) test -race -count=1 -p 1 ./...

vet:
	$(GO) vet ./...

vulncheck:
	$(GO) run golang.org/x/vuln/cmd/govulncheck@latest ./...

generate:
	$(GO) generate ./...

check: vet test-race vulncheck
	$(MAKE) -C macos test

# Native macOS app (builds the Go engine helper and bundles it).
app:
	$(MAKE) -C macos app
