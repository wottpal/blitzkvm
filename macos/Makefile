# Native macOS app: Swift/AppKit shell + Go engine helper (one per device).
#
#   make app        build "build/JetKVM Desktop.app" (arm64)
#   make test       Swift unit tests
#   make selftest   end-to-end run against the in-repo emulator
#   make run DEVICE=jetkvm.local
#   make install    copy the app to /Applications
#   make notarize   notarize and staple, for use on other Macs
#
# Signing: the keychain's first "Developer ID Application" identity, with the
# hardened runtime and a secure timestamp (both required for notarization).
# A stable identity keeps Accessibility and Local Network grants across
# rebuilds. Ad-hoc ("-") when there is none; override with SIGN_IDENTITY=...

DEVELOPER_DIR ?= $(shell test -d /Applications/Xcode.app && echo /Applications/Xcode.app/Contents/Developer || xcode-select -p)
export DEVELOPER_DIR
DEVELOPER_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | sed -n 's/^.*"\(Developer ID Application: .*\)"$$/\1/p' | head -n 1)
SIGN_IDENTITY ?= $(if $(DEVELOPER_ID),$(DEVELOPER_ID),-)
SIGN_FLAGS ?= $(if $(filter -,$(SIGN_IDENTITY)),,--options runtime --timestamp)
# Keychain profile for notarytool (see `notarize`).
NOTARY_PROFILE ?= jetkvm
APP := build/JetKVM Desktop.app
BUILD_NUMBER := $(shell git -C .. rev-list --count HEAD 2>/dev/null || echo 0)
EMULATOR_ADDR ?= 127.0.0.1:18080

.PHONY: app engine swift test selftest run install notarize clean

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
	codesign --force $(SIGN_FLAGS) --sign "$(SIGN_IDENTITY)" --identifier xyz.scio.jetkvm-mac.engine "$(APP)/Contents/Helpers/jetkvm-engine"
	codesign --force $(SIGN_FLAGS) --sign "$(SIGN_IDENTITY)" --identifier xyz.scio.jetkvm-mac "$(APP)"
	codesign --verify --strict --deep "$(APP)"
	@echo "built $(APP), signed by $(SIGN_IDENTITY)"

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

install: app
	rm -rf "/Applications/JetKVM Desktop.app"
	ditto "$(APP)" "/Applications/JetKVM Desktop.app"
	@echo "installed /Applications/JetKVM Desktop.app"

# Notarizes and staples the app so other Macs open it without warnings, and
# leaves build/JetKVM-Desktop.zip to hand out. One-time setup, which stores
# an app-specific password (appleid.apple.com) in the keychain:
#   xcrun notarytool store-credentials jetkvm --apple-id <apple-id> --team-id <team-id>
notarize: app
	@test "$(SIGN_IDENTITY)" != "-" || { echo "notarize needs a Developer ID Application identity" >&2; exit 2; }
	rm -f build/JetKVM-Desktop.zip
	ditto -c -k --keepParent "$(APP)" build/JetKVM-Desktop.zip
	xcrun notarytool submit build/JetKVM-Desktop.zip --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(APP)"
	rm -f build/JetKVM-Desktop.zip
	ditto -c -k --keepParent "$(APP)" build/JetKVM-Desktop.zip
	spctl --assess --type execute -vv "$(APP)"
	@echo "notarized: build/JetKVM-Desktop.zip"

run: app
	"$(APP)/Contents/MacOS/JetKVMDesktop" $(if $(DEVICE),--device $(DEVICE))

clean:
	rm -rf build .build
