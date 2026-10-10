SWIFT_JOBS ?= 2
INSTALL_ROOT ?= $(HOME)/.local/opt/agentbuild
BIN_DIR ?= $(HOME)/.local/bin

.PHONY: build release test install

build:
	@Scripts/with-compilation-lease swift build --jobs $(SWIFT_JOBS)

release:
	@Scripts/with-compilation-lease swift build --configuration release --jobs $(SWIFT_JOBS)

test:
	@Scripts/with-compilation-lease swift build --build-tests --jobs $(SWIFT_JOBS)
	@swift test --skip-build --jobs $(SWIFT_JOBS)

install: release
	@Scripts/install-tool .build/release/agentbuild "$(INSTALL_ROOT)" "$(BIN_DIR)"
