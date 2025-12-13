.PHONY: help setup install-swiftlint build test lint clean deps

# Detect OS
UNAME_S := $(shell uname -s)

# SwiftLint version
SWIFTLINT_VERSION := 0.57.0

help:
	@echo "Available targets:"
	@echo "  setup             - Install all dependencies (SwiftLint + Swift packages)"
	@echo "  install-swiftlint - Install SwiftLint"
	@echo "  deps              - Resolve Swift package dependencies"
	@echo "  build             - Build the project"
	@echo "  test              - Run tests"
	@echo "  lint              - Run SwiftLint"
	@echo "  clean             - Clean build artifacts"

setup: install-swiftlint deps
	@echo "✓ Setup complete"

install-swiftlint:
ifeq ($(UNAME_S),Darwin)
	@echo "Installing SwiftLint on macOS..."
	@if command -v swiftlint >/dev/null 2>&1; then \
		echo "✓ SwiftLint already installed (version: $$(swiftlint version))"; \
	else \
		if command -v brew >/dev/null 2>&1; then \
			brew install swiftlint; \
		else \
			echo "Error: Homebrew not found. Please install Homebrew first."; \
			exit 1; \
		fi; \
	fi
else ifeq ($(UNAME_S),Linux)
	@echo "Installing SwiftLint on Linux..."
	@if command -v swiftlint >/dev/null 2>&1; then \
		echo "✓ SwiftLint already installed (version: $$(swiftlint version))"; \
	else \
		echo "Downloading SwiftLint $(SWIFTLINT_VERSION) for Linux..."; \
		curl -L -o swiftlint.zip "https://github.com/realm/SwiftLint/releases/download/$(SWIFTLINT_VERSION)/swiftlint_linux.zip" && \
		unzip -o swiftlint.zip -d /tmp && \
		sudo mv /tmp/swiftlint /usr/local/bin/ && \
		sudo chmod +x /usr/local/bin/swiftlint && \
		rm swiftlint.zip && \
		echo "✓ SwiftLint installed successfully"; \
	fi
else
	@echo "Unsupported operating system: $(UNAME_S)"
	@exit 1
endif

deps:
	@echo "Resolving Swift package dependencies..."
	@cd imq-core && swift package resolve
	@cd imq-gui && swift package resolve
	@echo "✓ Dependencies resolved"

build:
	@echo "Building imq-core..."
	@cd imq-core && swift build
	@echo "Building imq-gui..."
	@cd imq-gui && swift build
	@echo "✓ Build complete"

test:
	@echo "Running tests for imq-core..."
	@cd imq-core && swift test
	@echo "Running tests for imq-gui..."
	@cd imq-gui && swift test
	@echo "✓ Tests complete"

lint:
	@echo "Running SwiftLint..."
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint lint; \
	else \
		echo "Error: SwiftLint not installed. Run 'make install-swiftlint' first."; \
		exit 1; \
	fi

lint-strict:
	@echo "Running SwiftLint in strict mode..."
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint lint --strict; \
	else \
		echo "Error: SwiftLint not installed. Run 'make install-swiftlint' first."; \
		exit 1; \
	fi

clean:
	@echo "Cleaning build artifacts..."
	@cd imq-core && swift package clean
	@cd imq-gui && swift package clean
	@rm -rf imq-core/.build
	@rm -rf imq-gui/.build
	@echo "✓ Clean complete"
