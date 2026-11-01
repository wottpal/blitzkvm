# blitzkvm-remote: the target side of remote approvals (README.md).
#
#   make -C remote          builds and signs build/ (the files install.sh takes)
#   make -C remote test     Swift tests, the PAM harness, the install scripts' lint
#
# Signing: the first "Developer ID Application" identity in the login
# keychain, ad hoc ("-") without one (the daemon then skips the agent's
# signature check and says so). The identifier is what the daemon requires
# of the agent.

DEVELOPER_DIR ?= $(shell test -d /Applications/Xcode.app && echo /Applications/Xcode.app/Contents/Developer || xcode-select -p)
export DEVELOPER_DIR
DEVELOPER_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | sed -n 's/^.*"\(Developer ID Application: .*\)"$$/\1/p' | head -n 1)
SIGN_IDENTITY ?= $(if $(DEVELOPER_ID),$(DEVELOPER_ID),-)
SIGN_FLAGS ?= $(if $(filter -,$(SIGN_IDENTITY)),,--options runtime --timestamp)
PACKAGE = blitzkvm-remote
BUILD = build

.PHONY: all test lint clean

all:
	swift build --package-path $(PACKAGE) -c release --arch arm64
	$(MAKE) -C pam
	mkdir -p $(BUILD)
	cp "$$(swift build --package-path $(PACKAGE) -c release --arch arm64 --show-bin-path)/blitzkvm-remote" $(BUILD)/
	cp pam/build/pam_blitzkvm.so $(BUILD)/
	cp install/*.plist install/install.sh install/uninstall.sh $(BUILD)/
	codesign --force $(SIGN_FLAGS) --sign "$(SIGN_IDENTITY)" --identifier xyz.scio.blitzkvm.remote $(BUILD)/blitzkvm-remote
	codesign --force $(SIGN_FLAGS) --sign "$(SIGN_IDENTITY)" --identifier xyz.scio.blitzkvm.remote.pam $(BUILD)/pam_blitzkvm.so
	@echo "built $(BUILD)/, signed by $(SIGN_IDENTITY)"

test: lint
	swift test --package-path $(PACKAGE)
	$(MAKE) -C pam test

lint:
	sh -n install/install.sh
	sh -n install/uninstall.sh
	@if command -v shellcheck >/dev/null; then shellcheck -s sh install/install.sh install/uninstall.sh; fi
	plutil -lint install/*.plist

clean:
	rm -rf $(BUILD) $(PACKAGE)/.build
	$(MAKE) -C pam clean
