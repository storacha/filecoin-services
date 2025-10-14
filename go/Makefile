# Makefile for Go bindings and libraries
SHELL := /bin/bash

.PHONY: all
all: generate

.PHONY: generate
generate:
	@echo "Generating all bindings and types..."
	./generate.sh

# Aliases for backwards compatibility
.PHONY: bindings
bindings: generate

.PHONY: evmerrors
evmerrors: generate

.PHONY: test
test:
	@echo "Testing Go modules..."
	go test ./...

.PHONY: test-abi
test-abi:
	@echo "Testing contract ABI compatibility..."
	go test ./eip712 -run TestContractABIAvailability -v
	go test ./eip712 -run TestEncodingMatchesContractDecoding -v

.PHONY: build
build: test-abi
	@echo "Building after ABI compatibility check..."
	go build ./...

.PHONY: clean
clean:
	@echo "Cleaning generated files..."
	rm -f bindings/*.go
	rm -f evmerrors/{errors,decoders,helpers}.go
	rm -rf bindings/abis evmerrors/abis tmpfile  # Clean any accidentally created temp files

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  all        - Generate all bindings and types (default)"
	@echo "  generate   - Generate contract bindings and error types"
	@echo "  bindings   - Alias for generate (backwards compatibility)"
	@echo "  evmerrors  - Alias for generate (backwards compatibility)"
	@echo "  test       - Run tests for all Go modules"
	@echo "  test-abi   - Test contract ABI compatibility"
	@echo "  build      - Build after ABI compatibility check"
	@echo "  clean      - Clean all generated files"
	@echo "  help       - Show this help message"
