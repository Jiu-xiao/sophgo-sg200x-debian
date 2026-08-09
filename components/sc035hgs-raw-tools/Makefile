override COMPONENT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BOARD ?= maixcam-sc035hgs
SDK_CACHE ?= $(COMPONENT_ROOT)/.cache/sdk
BOARD_BUILD_ROOT ?= $(COMPONENT_ROOT)/.cache/boards/$(BOARD)-sd
OUTPUT_DIR ?= $(COMPONENT_ROOT)/out
DESTDIR ?=
CROSS_COMPILE ?= riscv64-unknown-linux-musl-

.PHONY: all build test install clean

all: build

build:
	@BOARD="$(BOARD)" SDK_CACHE="$(SDK_CACHE)" \
		BOARD_BUILD_ROOT="$(BOARD_BUILD_ROOT)" OUTPUT_DIR="$(OUTPUT_DIR)" \
		CROSS_COMPILE="$(CROSS_COMPILE)" \
		bash "$(COMPONENT_ROOT)/ports/duo-sdk/build.sh"

test:
	@bash "$(COMPONENT_ROOT)/tests/run_host_tests.sh"

install: build
	@test -n "$(DESTDIR)" || { echo "DESTDIR is required" >&2; exit 2; }
	@install -d "$(DESTDIR)/usr/bin"
	@install -m 0755 "$(OUTPUT_DIR)/sc035hgs-test_mmf-raw" \
		"$(OUTPUT_DIR)/sc035hgs-raw-replay" \
		"$(OUTPUT_DIR)/sc035hgs-raw-unpack" \
		"$(OUTPUT_DIR)/sc035hgs-raw-session" \
		"$(OUTPUT_DIR)/sc035hgs-replay-tolerance" "$(DESTDIR)/usr/bin/"

clean:
	@test -n "$(OUTPUT_DIR)" && test "$(OUTPUT_DIR)" != "/"
	@rm -rf "$(OUTPUT_DIR)"
