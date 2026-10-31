SWIFT_JOBS ?= $(shell sysctl -n hw.logicalcpu)
BIN_DIR ?= $(HOME)/Developer/tools
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
	@Scripts/install-tool .build/release/agentbuild "$(BIN_DIR)"
