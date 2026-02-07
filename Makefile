BINARY := .build/release/geforcenow-awdl0
TARGET_BIN := $(HOME)/bin/geforcenow-awdl0
PLIST_TARGET := $(HOME)/Library/LaunchAgents/io.github.sjparkinson.geforcenow-awdl0.plist
UID := $(shell id -u)
LABEL := io.github.sjparkinson.geforcenow-awdl0

.PHONY: all build install uninstall run test clean

all: build

build:
	swift build -c release

install: build
	@echo "Installing geforcenow-awdl0..."
	@mkdir -p $(HOME)/bin
	@mkdir -p $(HOME)/Library/LaunchAgents
	@cp $(BINARY) $(TARGET_BIN)
	@chmod 755 $(TARGET_BIN)
	@cp ./LaunchAgents/io.github.sjparkinson.geforcenow-awdl0.plist $(PLIST_TARGET)
	@chmod 644 $(PLIST_TARGET)
	@echo "Loading LaunchAgent..."
	@launchctl bootout gui/$(UID)/$(LABEL) || true
	@launchctl bootstrap gui/$(UID) $(PLIST_TARGET) || echo "launchctl bootstrap failed"
	@echo "Installation complete."

uninstall:
	@echo "Uninstalling geforcenow-awdl0..."
	@launchctl bootout gui/$(UID)/$(LABEL) || true
	@rm -f $(PLIST_TARGET)
	@rm -f $(TARGET_BIN)
	@echo "Uninstallation complete."

run:
	@$(BINARY) --verbose

test:
	@swift test

clean:
	@swift package clean
