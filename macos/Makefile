# Native macOS app: Swift/AppKit shell + Go engine helper (one per device).
#
#   make app        build "build/JetKVM Desktop.app" (arm64)
#   make test       Swift unit tests
#   make icon       compile the Icon Composer source and standalone fallback
#   make firmware   bundle the JetKVM Desktop firmware (FORK_BINARY) for setup
#   make selftest   end-to-end run against the in-repo emulator
#   make selftest-stalls   the picture survives link stalls and hidden windows
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
# The JetKVM Desktop firmware build the setup sheet installs, pinned by
# Support/Firmware.json: the fork's (github.com/wottpal/kvm) bin/jetkvm_app.
FORK_BINARY ?= $(abspath ../../kvm/bin/jetkvm_app)

.PHONY: app engine swift icon firmware test selftest selftest-extras selftest-stalls run install notarize clean

engine:
	cd .. && GOARCH=arm64 go build -trimpath -ldflags "-s -w" -o macos/build/jetkvm-engine ./cmd/jetkvm-engine

swift:
	swift build -c release --arch arm64

icon:
	sh scripts/make-icon.sh

firmware:
	sh scripts/bundle-firmware.sh "$(FORK_BINARY)" Support/Firmware.json build/firmware

app: engine swift icon firmware
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Helpers" "$(APP)/Contents/Resources"
	cp "$$(swift build -c release --arch arm64 --show-bin-path)/JetKVMDesktop" "$(APP)/Contents/MacOS/JetKVMDesktop"
	cp build/jetkvm-engine "$(APP)/Contents/Helpers/jetkvm-engine"
	sed "s/@BUILD@/$(BUILD_NUMBER)/" Support/Info.plist.in > "$(APP)/Contents/Info.plist"
	cp Support/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	cp build/icon/Assets.car "$(APP)/Contents/Resources/Assets.car"
	if [ -f build/firmware/jetkvm_app.gz ]; then \
		mkdir -p "$(APP)/Contents/Resources/Firmware" && \
		cp build/firmware/jetkvm_app.gz build/firmware/Firmware.json "$(APP)/Contents/Resources/Firmware/"; \
	fi
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
	"$(APP)/Contents/MacOS/JetKVMDesktop" --device $(EMULATOR_ADDR) --selftest 8 --crash-engine-after 4 --inject-input --h264 --snapshot "$(CURDIR)/build/selftest.png"; status=$$?; \
	kill $$(cat build/emulator.pid); rm -f build/emulator.pid; \
	test $$status -eq 0 || exit $$status; \
	grep -q '"Type":"hidrpc.Keypress","Data":"{Key:4 Press:true}"' build/emulator-inputs.jsonl || { echo "key A not received"; exit 1; }; \
	grep -q '"Data":"{Key:225 Press:true}"' build/emulator-inputs.jsonl || { echo "Shift not received"; exit 1; }; \
	grep -q '"Type":"hidrpc.Pointer","Data":"{X:16384 Y:16384 Buttons:1}"' build/emulator-inputs.jsonl || { echo "click not received"; exit 1; }; \
	if command -v ffmpeg >/dev/null; then \
		ffmpeg -v error -y -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 4 -pix_fmt yuv420p -c:v libx265 -x265-params bframes=0:keyint=15:log-level=error \
			-bsf:v hevc_metadata=aud=insert -f hevc build/selftest.h265 || exit 1; \
		./build/emulator-serve serve --listen $(EMULATOR_ADDR) --width 1920 --height 1080 --fps 30 --replay-h265 build/selftest.h265 > /dev/null 2>&1 & pid=$$!; \
		sleep 1; \
		"$(APP)/Contents/MacOS/JetKVMDesktop" --device $(EMULATOR_ADDR) --selftest 4 --view-only > build/selftest-h265.json; status=$$?; \
		kill $$pid; \
		test $$status -eq 0 && grep -q '"codec" : "H.265"' build/selftest-h265.json || { cat build/selftest-h265.json; echo "H.265 decode failed"; exit 1; }; \
	else echo "ffmpeg not installed: H.265 pass skipped"; fi; \
	echo "selftest passed: video (H.264 live pattern, H.265 clip), keyboard and pointer input, and engine recovery verified"

# The picture must never stand still while frames arrive. Against an
# emulator with the patched firmware's keyframe policy (one a minute, or on
# request): 400 ms link stalls whose frames then arrive in a burst, and a
# window hidden for 2 s and shown again. Each may freeze the picture only
# about as long as the stall itself.
selftest-stalls: app
	cd .. && go build -o macos/build/emulator-serve ./test/emulator-serve
	@for run in stalls hide; do \
		./build/emulator-serve serve --listen $(EMULATOR_ADDR) --width 1920 --height 1080 --fps 60 --gop 3600 --keyframe-on-request \
			$$([ $$run = stalls ] && echo --hold-every 3s --hold-for 400ms --rate 200e6) > /dev/null 2>&1 & pid=$$!; \
		sleep 1; \
		"$(APP)/Contents/MacOS/JetKVMDesktop" --device $(EMULATOR_ADDR) --selftest 12 --view-only --h264 \
			$$([ $$run = stalls ] && echo --max-freeze-ms 700 || echo --hide-after 4 --max-freeze-ms 1000) > build/selftest-$$run.json; status=$$?; \
		kill $$pid; \
		test $$status -eq 0 || { cat build/selftest-$$run.json; echo "selftest-stalls ($$run) failed"; exit 1; }; \
	done
	@echo "selftest-stalls passed: no freeze beyond a link stall, and the picture resumes when the window is shown"

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
		"$(APP)/Contents/MacOS/JetKVMDesktop" --device $$scheme://127.0.0.1:$$port --selftest 15 --exercise-extras --view-only --h264 > build/selftest-extras-$$scheme.json; status=$$?; \
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
