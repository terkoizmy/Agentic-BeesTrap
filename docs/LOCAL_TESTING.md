# 🐝 BeeTrap Local Testing Guide

Step-by-step guide to run the entire BeeTrap system locally using Anvil.

## Prerequisites

```bash
# Check you have these installed
foundry --version    # Foundry (forge, anvil, cast)
cargo --version      # Rust
```

---

## Step 1: Start Anvil (Terminal 1)

Open a new terminal and start Anvil:

```bash
# Start local Ethereum node
anvil --chain-id 31337 --block-time 2
```

You'll see output like:
```
Available Accounts
==================
(0) 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 (10000 ETH)
(1) 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 (10000 ETH)
...

Private Keys
==================
(0) 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
...

Listening on 127.0.0.1:8545
```

**Leave this terminal running!**

---

## Step 2: Deploy Contracts (Terminal 2)

Open another terminal:

```bash
cd contracts

# Deploy all contracts
forge script script/DeployBeeTrap.s.sol:DeployBeeTrap \
    --rpc-url http://localhost:8545 \
    --broadcast \
    -vvv
```

**Copy the addresses from the output** and update your `.env`:

```env
POOL_MANAGER_ADDRESS=0x5FbDB...
AGENT_NFT_ADDRESS=0xe7f17...
VALIDATION_REGISTRY_ADDRESS=0x9fE46...
HOOK_ADDRESS=0xCf7Ed...
```

---

## Step 3: Setup Agent

After setting the addresses in `.env`:

```bash
# Source the environment
source ../.env

# Export for forge script
export AGENT_NFT_ADDRESS
export VALIDATION_REGISTRY_ADDRESS

# Run setup script
forge script script/DeployBeeTrap.s.sol:SetupAgent \
    --rpc-url http://localhost:8545 \
    --broadcast \
    -vvv
```

This will:
1. Mint Agent NFT #0 to your address
2. Register it in ValidationRegistry with model hash

---

## Step 4: Run the Sentinel

```bash
cd ../agent

# Run the TUI sentinel
cargo run --release
```

You should see the **cyberpunk dashboard** with:
- Network status showing "Anvil" 
- Transactions flowing through
- Detections appearing in the alerts panel

**Press `q` to quit.**

---

## Quick Test Commands

### Check Contract Deployment
```bash
# Get AgentNFT owner
cast call $AGENT_NFT_ADDRESS "owner()" --rpc-url http://localhost:8545

# Check if agent is registered
cast call $VALIDATION_REGISTRY_ADDRESS \
    "getAgentConfig(uint256)(bytes32,address,address,uint8,bool)" 0 \
    --rpc-url http://localhost:8545
```

### Manual Detection Test
```bash
# Mark an address as predator (simulating the sentinel)
cast send $HOOK_ADDRESS \
    "markAsPredator(address,bool)" \
    0x0000000000000000000000000000000000000Bad true \
    --private-key $PRIVATE_KEY \
    --rpc-url http://localhost:8545
```

---

## Troubleshooting

### "Contract not found"
Make sure you're using the correct addresses from deployment output.

### "Anvil not running"
Check Terminal 1 is still running anvil.

### TUI looks broken
Make sure your terminal supports Unicode and 256 colors.

---

## File Structure

```
Agentic-BeesTrap/
├── .env                    # Configuration (update addresses here)
├── scripts/
│   └── local-test.sh       # Automation script
├── contracts/
│   ├── src/
│   │   ├── AgentNFT.sol
│   │   ├── ValidationRegistry.sol
│   │   └── BeeTrapHook.sol
│   └── script/
│       └── DeployBeeTrap.s.sol
└── agent/
    └── src/
        ├── main.rs
        └── ui/dashboard.rs
```
