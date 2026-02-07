BINARY := .build/release/geforcenow-awdl0
TARGET_BIN := $(HOME)/bin/geforcenow-awdl0
PLIST_TARGET := $(HOME)/Library/LaunchAgents/io.github.sjparkinson.geforcenow-awdl0.plist
UID := $(shell id -u)
LABEL := io.github.sjparkinson.geforcenow-awdl0
SRCS := $(shell find Sources -type f -name '*.swift')

.PHONY: all install uninstall run test clean

all: $(BINARY)

$(BINARY): $(SRCS)
     swift build -c release

build: $(BINARY)

install: build
	@echo "Installing geforcenow-awdl0..."
	@mkdir -p $(HOME)/bin
	@mkdir -p $(HOME)/Library/LaunchAgents
	@mkdir -p $(HOME)/Library/Logs
	@cp $(BINARY) $(TARGET_BIN)
	@chmod 755 $(TARGET_BIN)
	@sed -e "s|__TARGET_BIN__|$(TARGET_BIN)|g" \
		-e "s|__LOG_PATH__|$(HOME)/Library/Logs/geforcenow-awdl0.log|g" \
		./LaunchAgents/io.github.sjparkinson.geforcenow-awdl0.plist > $(PLIST_TARGET)
	@chmod 644 $(PLIST_TARGET)
	@echo "Loading LaunchAgent..."
	@launchctl bootstrap gui/$(UID) $(PLIST_TARGET)
	@echo "Installation complete."

uninstall:
	@echo "Uninstalling geforcenow-awdl0..."
	@launchctl bootout gui/$(UID)/$(LABEL)
	@rm -f $(PLIST_TARGET)
	@rm -f $(TARGET_BIN)
	@echo "Uninstallation complete."

run:
	@$(BINARY) --verbose

test:
	@swift test

clean:
	@swift package clean
