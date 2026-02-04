#!/bin/bash
set -e

echo "=========================================="
echo "Filecoin Local Development Environment"
echo "=========================================="
echo

# Configuration
ANVIL_PORT="${ANVIL_PORT:-8546}"
RPC_PORT="${RPC_PORT:-8545}"
ANVIL_BLOCK_TIME="${ANVIL_BLOCK_TIME:-1}"  # Default: 1 second
STATE_FILE="/app/anvil-state.json"
DUMP_STATE="${DUMP_STATE:-false}"

echo "Block mining: Every ${ANVIL_BLOCK_TIME}s"
echo "Anvil port: $ANVIL_PORT (internal)"
echo "RPC port: $RPC_PORT (external)"
echo

# ===========================================
# MODE 1: DUMP STATE MODE
# Deploys contracts and exports state file
# ===========================================
if [ "$DUMP_STATE" = "true" ]; then
    echo "=========================================="
    echo "DUMP STATE MODE"
    echo "=========================================="
    echo
    echo "Will deploy contracts and export state to /output/anvil-state.json"
    echo

    # Start Anvil with --dump-state flag (writes JSON on exit)
    anvil --host 0.0.0.0 --port $ANVIL_PORT --dump-state /tmp/anvil-state.json \
          --block-time $ANVIL_BLOCK_TIME &
    ANVIL_PID=$!

    # Wait for Anvil to be ready
    echo "Waiting for Anvil to be ready..."
    for i in {1..30}; do
        if cast chain-id --rpc-url "http://localhost:$ANVIL_PORT" > /dev/null 2>&1; then
            echo "Anvil is ready!"
            break
        fi
        if [ $i -eq 30 ]; then
            echo "ERROR: Anvil failed to start"
            exit 1
        fi
        sleep 0.5
    done

    echo
    echo "=========================================="
    echo "Deploying Contracts"
    echo "=========================================="
    echo

    # Deploy contracts
    ANVIL_RPC="http://localhost:$ANVIL_PORT" OUTPUT_FILE="/deployed-addresses.json" \
        /app/service_contracts/localdev/scripts/deploy-local.sh

    echo
    echo "=========================================="
    echo "Exporting State"
    echo "=========================================="
    echo

    # Gracefully stop Anvil to trigger state dump
    echo "Stopping Anvil to trigger state dump..."
    kill -TERM $ANVIL_PID

    # Wait for Anvil to exit and write state file
    wait $ANVIL_PID 2>/dev/null || true

    # Give filesystem a moment to sync
    sleep 1

    # Check if state file was created
    if [ ! -f /tmp/anvil-state.json ]; then
        echo "ERROR: State file was not created!"
        exit 1
    fi

    # Copy to output mount
    if [ -d /output ]; then
        cp /tmp/anvil-state.json /output/anvil-state.json
        cp /deployed-addresses.json /output/deployed-addresses.json
        echo "State dumped to /output/anvil-state.json"
        echo "Addresses dumped to /output/deployed-addresses.json"
        ls -lh /output/anvil-state.json
    else
        echo "WARNING: /output directory not mounted!"
        echo "State file is at /tmp/anvil-state.json inside container"
    fi

    echo
    echo "=========================================="
    echo "State Export Complete!"
    echo "=========================================="
    echo
    echo "To use this state file:"
    echo "  docker run -v \$(pwd)/anvil-state.json:/app/anvil-state.json filecoin-localdev"
    echo
    exit 0
fi

# ===========================================
# MODE 2: LOAD STATE MODE
# Fast startup with pre-existing state
# ===========================================
if [ -f "$STATE_FILE" ]; then
    echo "=========================================="
    echo "Loading Pre-existing State"
    echo "=========================================="
    echo
    echo "Found state file at $STATE_FILE"
    echo "Skipping contract deployment..."
    echo

    # Start Anvil with pre-loaded state
    anvil --host 0.0.0.0 --port $ANVIL_PORT --load-state "$STATE_FILE" \
          --block-time $ANVIL_BLOCK_TIME --silent &
    ANVIL_PID=$!

    # Wait for Anvil to be ready
    echo "Waiting for Anvil to load state..."
    for i in {1..30}; do
        if cast chain-id --rpc-url "http://localhost:$ANVIL_PORT" > /dev/null 2>&1; then
            echo "Anvil is ready with loaded state!"
            break
        fi
        if [ $i -eq 30 ]; then
            echo "ERROR: Anvil failed to start with loaded state"
            exit 1
        fi
        sleep 0.5
    done

# ===========================================
# MODE 3: NORMAL MODE
# Fresh deployment from scratch
# ===========================================
else
    echo "=========================================="
    echo "Starting Fresh Anvil Instance"
    echo "=========================================="
    echo
    echo "No state file found, will deploy contracts..."
    echo

    # Start Anvil in background
    anvil --host 0.0.0.0 --port $ANVIL_PORT --block-time $ANVIL_BLOCK_TIME --silent &
    ANVIL_PID=$!

    # Wait for Anvil to be ready
    echo "Waiting for Anvil to be ready..."
    for i in {1..30}; do
        if cast chain-id --rpc-url "http://localhost:$ANVIL_PORT" > /dev/null 2>&1; then
            echo "Anvil is ready!"
            break
        fi
        if [ $i -eq 30 ]; then
            echo "ERROR: Anvil failed to start"
            exit 1
        fi
        sleep 0.5
    done

    echo
    echo "=========================================="
    echo "Deploying Contracts"
    echo "=========================================="
    echo

    # Deploy contracts
    ANVIL_RPC="http://localhost:$ANVIL_PORT" OUTPUT_FILE="/deployed-addresses.json" \
        /app/service_contracts/localdev/scripts/deploy-local.sh
fi

echo
echo "=========================================="
echo "Starting Mock Lotus RPC Server"
echo "=========================================="
echo

# Start the mock RPC server
export LISTEN_ADDR=":$RPC_PORT"
export ANVIL_ADDR="http://localhost:$ANVIL_PORT"

/app/mockrpc/mockrpc &
MOCKRPC_PID=$!

# Wait a moment for the server to start
sleep 1

echo
echo "=========================================="
echo "Local Environment Ready!"
echo "=========================================="
echo
echo "Connect your application to:"
echo "  RPC URL: http://localhost:$RPC_PORT"
echo "  Chain ID: 31337"
echo
echo "Contract addresses: cat /deployed-addresses.json"
echo
echo "Pre-funded Accounts:"
echo "  Deployer:  0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
echo "  Payer:     0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
echo "  Provider:  0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
echo

# Handle shutdown
cleanup() {
    echo "Shutting down..."
    kill $MOCKRPC_PID 2>/dev/null || true
    kill $ANVIL_PID 2>/dev/null || true
    exit 0
}

trap cleanup SIGTERM SIGINT

# Keep container running
wait $ANVIL_PID $MOCKRPC_PID
