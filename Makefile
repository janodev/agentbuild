SWIFT_JOBS ?= $(shell sysctl -n hw.logicalcpu)
INSTALL_ROOT ?= $(HOME)/.local/opt/agentbuild
BIN_DIR ?= $(HOME)/.local/bin
export TEST_FILTER

.PHONY: build release test install

build:
	@Scripts/with-compilation-lease swift build --jobs $(SWIFT_JOBS)

release:
	@Scripts/with-compilation-lease swift build --configuration release --jobs $(SWIFT_JOBS)

test:
	@Scripts/with-compilation-lease swift build --build-tests --jobs $(SWIFT_JOBS)
	@set -eu; set --; if [ -n "$${TEST_FILTER:-}" ]; then set -- --filter "$$TEST_FILTER"; fi; \
		swift test --skip-build --no-parallel --jobs $(SWIFT_JOBS) "$$@"

install: release
	@Scripts/install-tool .build/release/agentbuild "$(INSTALL_ROOT)" "$(BIN_DIR)"
