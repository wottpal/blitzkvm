# Native macOS app: Swift/AppKit shell + Go engine helper (one per device).
#
#   make app        build "build/JetKVM Desktop.app" (arm64)
#   make test       Swift unit tests
#   make selftest   end-to-end run against the in-repo emulator
#   make run DEVICE=jetkvm.local
#
# Signing: set SIGN_IDENTITY to a Developer ID / Apple Development identity so
# Accessibility and Local Network grants survive rebuilds; ad-hoc otherwise.

DEVELOPER_DIR ?= $(shell test -d /Applications/Xcode.app && echo /Applications/Xcode.app/Contents/Developer || xcode-select -p)
export DEVELOPER_DIR
SIGN_IDENTITY ?= -
APP := build/JetKVM Desktop.app
BUILD_NUMBER := $(shell git -C .. rev-list --count HEAD 2>/dev/null || echo 0)
EMULATOR_ADDR ?= 127.0.0.1:18080

.PHONY: app engine swift test selftest run clean

engine:
	cd .. && GOARCH=arm64 go build -trimpath -ldflags "-s -w" -o macos/build/jetkvm-engine ./cmd/jetkvm-engine

swift:
	swift build -c release --arch arm64

app: engine swift
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Helpers" "$(APP)/Contents/Resources"
	cp "$$(swift build -c release --arch arm64 --show-bin-path)/JetKVMDesktop" "$(APP)/Contents/MacOS/JetKVMDesktop"
	cp build/jetkvm-engine "$(APP)/Contents/Helpers/jetkvm-engine"
	sed "s/@BUILD@/$(BUILD_NUMBER)/" Support/Info.plist.in > "$(APP)/Contents/Info.plist"
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier xyz.scio.jetkvm-mac.engine "$(APP)/Contents/Helpers/jetkvm-engine"
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier xyz.scio.jetkvm-mac "$(APP)"
	@echo "built $(APP)"

test:
	swift test

# Starts the emulator, runs the app's self-test (synthetic keyboard and mouse
# input, an engine crash and recovery) and fails unless frames were decoded
# and presented and the emulator received the input.
selftest: app
	cd .. && go build -o macos/build/emulator-serve ./test/emulator-serve
	./build/emulator-serve serve --listen $(EMULATOR_ADDR) --width 1280 --height 720 --fps 30 --log-inputs > build/emulator-inputs.jsonl & echo $$! > build/emulator.pid; \
	sleep 1; \
	"$(APP)/Contents/MacOS/JetKVMDesktop" --device $(EMULATOR_ADDR) --selftest 8 --crash-engine-after 4 --inject-input --snapshot "$(CURDIR)/build/selftest.png"; status=$$?; \
	kill $$(cat build/emulator.pid); rm -f build/emulator.pid; \
	test $$status -eq 0 || exit $$status; \
	grep -q '"Type":"hidrpc.Keypress","Data":"{Key:4 Press:true}"' build/emulator-inputs.jsonl || { echo "key A not received"; exit 1; }; \
	grep -q '"Data":"{Key:225 Press:true}"' build/emulator-inputs.jsonl || { echo "Shift not received"; exit 1; }; \
	grep -q '"Type":"hidrpc.Pointer","Data":"{X:16384 Y:16384 Buttons:1}"' build/emulator-inputs.jsonl || { echo "click not received"; exit 1; }; \
	echo "selftest passed: video, input and engine recovery verified"

run: app
	"$(APP)/Contents/MacOS/JetKVMDesktop" $(if $(DEVICE),--device $(DEVICE))

clean:
	rm -rf build .build
