# Top-level Makefile for filecoin-services
SHELL := /bin/bash

.PHONY: all
all: contracts bindings

.PHONY: contracts
contracts:
	@echo "Building Solidity contracts..."
	$(MAKE) -C service_contracts gen
	$(MAKE) -C service_contracts build
	@echo "Building submodule contracts..."
	$(MAKE) -C service_contracts/lib/fws-payments build
	$(MAKE) -C service_contracts/lib/pdp build
	$(MAKE) -C service_contracts update-abi

.PHONY: bindings
bindings: contracts
	@echo "Generating Go bindings..."
	$(MAKE) -C go all

.PHONY: test-go
test-go: bindings
	@echo "Testing Go modules..."
	$(MAKE) -C go test

.PHONY: test-contracts
test-contracts:
	@echo "Testing Solidity contracts..."
	$(MAKE) -C service_contracts test

.PHONY: test
test: test-contracts test-go

.PHONY: install
	$(MAKE) -C service_contracts install

.PHONY: clean
clean:
	@echo "Cleaning build artifacts..."
	$(MAKE) -C service_contracts clean-all
	$(MAKE) -C go clean