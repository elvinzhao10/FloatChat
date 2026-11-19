APP_NAME := FloatChat
APP      := build/$(APP_NAME).app
PREFIX   ?= /Applications
DEST     := $(PREFIX)/$(APP_NAME).app

# Quit any running copy (any bundle id/location). SIGTERM makes the app restore ChatGPT's keymap.
QUIT := pkill -x FloatChat && while pgrep -xq FloatChat; do sleep 0.2; done; true

SWIFT_BUILD_FLAGS ?=

.PHONY: app build check run install uninstall clean

app:
	./scripts/build-app.sh

build: app

check:
	@set -e; for script in scripts/*.sh; do bash -n "$$script"; done
	swift test $(SWIFT_BUILD_FLAGS)
	@set -e; bin="$$(swift build $(SWIFT_BUILD_FLAGS) --show-bin-path)/FloatChat"; \
	for mode in pages language shortcuts panel; do FLOATCHAT_SELFTEST="$$mode" "$$bin"; done

run: app
	@$(QUIT)
	open "$(APP)"

install: app
	@$(QUIT)
	mkdir -p "$(PREFIX)"
	rm -rf "$(DEST)"
	ditto "$(APP)" "$(DEST)"
	@echo "Installed $(DEST)"

uninstall:
	@$(QUIT)
	rm -rf "$(DEST)"

clean:
	rm -rf .build build
