#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#                      BEETRAP LOCAL TESTING SCRIPT
# ═══════════════════════════════════════════════════════════════════════════
# This script helps you run the entire BeeTrap system locally
#
# Prerequisites:
#   - Foundry (forge, anvil, cast)
#   - Rust & Cargo
#
# Usage:
#   chmod +x scripts/local-test.sh
#   ./scripts/local-test.sh [command]
#
# Commands:
#   anvil     - Start local Anvil node
#   deploy    - Deploy contracts to Anvil
#   setup     - Setup agent (mint NFT + register)
#   sentinel  - Run the Rust sentinel
#   all       - Run everything in sequence
# ═══════════════════════════════════════════════════════════════════════════

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Default Anvil settings
ANVIL_RPC="http://localhost:8545"
ANVIL_WS="ws://localhost:8545"
ANVIL_CHAIN_ID=31337

# Anvil's default account #0
ANVIL_PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

# Project paths
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACTS_DIR="$PROJECT_ROOT/contracts"
AGENT_DIR="$PROJECT_ROOT/agent"

echo -e "${CYAN}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║           🐝 BEETRAP LOCAL TESTING ENVIRONMENT 🐝          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ───────────────────────────────────────────────────────────────────────────
# FUNCTIONS
# ───────────────────────────────────────────────────────────────────────────

start_anvil() {
    echo -e "${GREEN}[1] Starting Anvil...${NC}"
    echo "    RPC: $ANVIL_RPC"
    echo "    Chain ID: $ANVIL_CHAIN_ID"
    echo ""
    
    # Start Anvil in background with verbose output
    anvil --chain-id $ANVIL_CHAIN_ID --block-time 2 &
    ANVIL_PID=$!
    
    echo -e "${YELLOW}    Anvil PID: $ANVIL_PID${NC}"
    echo "    Waiting for Anvil to start..."
    sleep 3
    
    # Test connection
    if cast block-number --rpc-url $ANVIL_RPC > /dev/null 2>&1; then
        echo -e "${GREEN}    ✅ Anvil is running!${NC}"
    else
        echo -e "${RED}    ❌ Failed to connect to Anvil${NC}"
        exit 1
    fi
    echo ""
}

deploy_contracts() {
    echo -e "${GREEN}[2] Deploying Contracts...${NC}"
    cd "$CONTRACTS_DIR"
    
    # Run deployment script
    forge script script/DeployBeeTrap.s.sol:DeployBeeTrap \
        --rpc-url $ANVIL_RPC \
        --broadcast \
        -vvv
    
    echo ""
}

setup_agent() {
    echo -e "${GREEN}[3] Setting up Agent...${NC}"
    
    # You need to set these from the deployment output
    if [ -z "$AGENT_NFT_ADDRESS" ]; then
        echo -e "${YELLOW}    Please set AGENT_NFT_ADDRESS and VALIDATION_REGISTRY_ADDRESS${NC}"
        echo "    Example:"
        echo "      export AGENT_NFT_ADDRESS=0x..."
        echo "      export VALIDATION_REGISTRY_ADDRESS=0x..."
        return 1
    fi
    
    cd "$CONTRACTS_DIR"
    
    forge script script/DeployBeeTrap.s.sol:SetupAgent \
        --rpc-url $ANVIL_RPC \
        --broadcast \
        -vvv
    
    echo ""
}

run_sentinel() {
    echo -e "${GREEN}[4] Starting Rust Sentinel...${NC}"
    cd "$AGENT_DIR"
    
    # Set environment variables
    export RPC_URL=$ANVIL_WS
    export CHAIN_ID=$ANVIL_CHAIN_ID
    export PRIVATE_KEY=${ANVIL_PRIVATE_KEY#0x}  # Remove 0x prefix
    export CONFIDENCE_THRESHOLD=0.8
    
    echo "    RPC_URL: $RPC_URL"
    echo "    CHAIN_ID: $CHAIN_ID"
    echo ""
    
    cargo run --release
}

show_help() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  anvil     Start local Anvil node"
    echo "  deploy    Deploy contracts to Anvil"
    echo "  setup     Setup agent (mint NFT + register)"
    echo "  sentinel  Run the Rust sentinel"
    echo "  all       Run everything in sequence"
    echo "  help      Show this help message"
    echo ""
    echo "Example workflow:"
    echo "  Terminal 1: $0 anvil"
    echo "  Terminal 2: $0 deploy"
    echo "  Terminal 2: $0 sentinel"
}

# ───────────────────────────────────────────────────────────────────────────
# MAIN
# ───────────────────────────────────────────────────────────────────────────

case "${1:-help}" in
    anvil)
        start_anvil
        echo -e "${CYAN}Anvil is running. Press Ctrl+C to stop.${NC}"
        wait $ANVIL_PID
        ;;
    deploy)
        deploy_contracts
        ;;
    setup)
        setup_agent
        ;;
    sentinel)
        run_sentinel
        ;;
    all)
        echo -e "${YELLOW}Running full setup...${NC}"
        start_anvil
        sleep 2
        deploy_contracts
        # setup_agent  # Manual step needed
        echo ""
        echo -e "${CYAN}Deployment complete! Now run the sentinel:${NC}"
        echo "  cd agent && cargo run --release"
        ;;
    *)
        show_help
        ;;
esac
