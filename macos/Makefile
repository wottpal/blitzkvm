# Native macOS app: Swift/AppKit shell + Go engine helper (one per device).
#
#   make app        build "build/JetKVM Desktop.app" (arm64)
#   make test       Swift unit tests
#   make selftest   end-to-end run against the in-repo emulator
#   make run DEVICE=jetkvm.local
#   make install    copy the app to /Applications
#   make notarize   notarize (Xcode account) and staple, for use on other Macs
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
# The signing identity's team, for notarization.
TEAM_ID ?= $(shell echo '$(SIGN_IDENTITY)' | sed -n 's/.*(\([A-Z0-9]\{10\}\))$$/\1/p')
# Every signed build is also copied here (empty to skip).
COPY_TO ?= $(HOME)/Downloads
define copy_signed
	@if [ "$(SIGN_IDENTITY)" != "-" ] && [ -n "$(COPY_TO)" ]; then \
		rm -rf "$(COPY_TO)/JetKVM Desktop.app" && ditto "$(APP)" "$(COPY_TO)/JetKVM Desktop.app" && \
		echo "copied to $(COPY_TO)/JetKVM Desktop.app"; \
	fi
endef
APP := build/JetKVM Desktop.app
BUILD_NUMBER := $(shell git -C .. rev-list --count HEAD 2>/dev/null || echo 0)
EMULATOR_ADDR ?= 127.0.0.1:18080

.PHONY: app engine swift test selftest selftest-extras run install notarize clean

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
	$(copy_signed)

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

# Notarizes with the Apple ID signed into Xcode (Settings → Accounts; no
# app-specific password), staples, and leaves build/JetKVM-Desktop.zip to
# hand out (also copied to COPY_TO). See scripts/notarize.sh.
notarize: app
	@test "$(SIGN_IDENTITY)" != "-" || { echo "notarize needs a Developer ID Application identity" >&2; exit 2; }
	scripts/notarize.sh "$(APP)" "$(TEAM_ID)" build/notarized
	rm -rf "$(APP)"
	ditto "build/notarized/JetKVM Desktop.app" "$(APP)"
	rm -f build/JetKVM-Desktop.zip
	ditto -c -k --keepParent "$(APP)" build/JetKVM-Desktop.zip
	$(copy_signed)
	@if [ -n "$(COPY_TO)" ]; then cp build/JetKVM-Desktop.zip "$(COPY_TO)/JetKVM-Desktop.zip" && echo "copied to $(COPY_TO)/JetKVM-Desktop.zip"; fi
	@echo "notarized: build/JetKVM-Desktop.zip"

# Virtual media, serial console and address probing through the app, over
# http and over https (self-signed device CA, pinned on first use).
selftest-extras: app
	cd .. && go build -o macos/build/emulator-serve ./test/emulator-serve
	@for scheme in http https; do \
		port=$$([ $$scheme = https ] && echo 18443 || echo 18081); \
		./build/emulator-serve serve --listen 127.0.0.1:$$port $$([ $$scheme = https ] && echo --tls) --log-inputs > build/emulator-extras.jsonl & pid=$$!; \
		sleep 1; \
		"$(APP)/Contents/MacOS/JetKVMDesktop" --device $$scheme://127.0.0.1:$$port --selftest 15 --exercise-extras --view-only > build/selftest-extras-$$scheme.json; status=$$?; \
		kill $$pid; \
		cat build/selftest-extras-$$scheme.json; \
		test $$status -eq 0 || { echo "selftest-extras ($$scheme) failed"; exit 1; }; \
		grep -q '"Type":"serial.tx","Data":"selftest-serial\\r"' build/emulator-extras.jsonl || { echo "serial input not received ($$scheme)"; exit 1; }; \
	done
	@echo "selftest-extras passed: virtual media, serial console and probing over http and https"

run: app
	"$(APP)/Contents/MacOS/JetKVMDesktop" $(if $(DEVICE),--device $(DEVICE))

clean:
	rm -rf build .build
