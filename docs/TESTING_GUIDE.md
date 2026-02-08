# BeeTrap End-to-End Testing Guide

This guide walks you through deploying the BeeTrap system, configuring the Agent, and verifying the predator detection logic on a local Anvil chain.

## 1. Prerequisites

Ensure you have the following installed:
- `foundry` (forge, cast, anvil)
- `rust` (cargo)

## 2. Start Local Blockchain

Open a **new terminal** and start Anvil. This creates a fresh local blockchain.

```bash
anvil
```

*Keep this terminal open.*

## 3. Deploy Contracts

In your **main terminal**, run the deployment script.

```bash
# Execute deployment script
forge script script/DeployBeeTrap_update.s.sol \
  --tc DeployBeeTrap \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

## 4. Configure Agent

The agent needs to know the addresses of the newly deployed contracts.

### A. Get Deployment Addresses
Run this command to see the latest deployment addresses:

```bash
cat contracts/broadcast/DeployBeeTrap_update.s.sol/31337/run-latest.json | grep -E "contractAddress|contractName"
```

Find the addresses for `AgentNFT` and `BeeTrapHook`.

### B. Update `.env`
Update your `.env` file (and `agent/.env` if it's separate) with the new addresses. You can use these commands (replace the addresses with YOUR output from step A):

```bash
# Example Addresses (REPLACE THESE with your actual deployment output)
NEW_AGENT_NFT="0x..." 
NEW_HOOK="0x..."

# Verify current values
grep -E "AGENT_NFT_ADDRESS|HOOK_ADDRESS" .env

# Update .env (Root)
sed -i "s/^AGENT_NFT_ADDRESS=.*/AGENT_NFT_ADDRESS=$NEW_AGENT_NFT/" .env
sed -i "s/^HOOK_ADDRESS=.*/HOOK_ADDRESS=$NEW_HOOK/" .env

# Update agent/.env (Agent)
sed -i "s/^AGENT_NFT_ADDRESS=.*/AGENT_NFT_ADDRESS=$NEW_AGENT_NFT/" agent/.env
sed -i "s/^HOOK_ADDRESS=.*/HOOK_ADDRESS=$NEW_HOOK/" agent/.env
```

## 5. Run the AI Agent

Ensure no conflicting environment variables are set, then start the agent.

```bash
# Clear RPC_URL to avoid "URL scheme" errors
unset RPC_URL

# Navigate and Run
cd agent
cargo run --release
```

*The agent should start and listen for transactions.*

## 6. Manual Verification (Simulating Detection)

Since we cannot easily "act" like a predator to trigger the AI model deterministically without a replay script, we will **manually submit a pre-calculated Proof** to verify the on-chain logic works.

This command replicates exactly what the Agent does when it catches a predator.

### Setup Variables
```bash
# Go back to root if needed
cd .. 

export RPC_URL="http://127.0.0.1:8545"
export PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

# Addresses from Step 4
export AGENT_NFT="0x610178dA211FEF7D417bC0e6FeD39F05609AD788" # REPLACE THIS
export HOOK="0xa3Dcc022133153c441799d03674BbBCC16D840bd"      # REPLACE THIS

# The "Predator" address to ban
export PREDATOR="0x62425cD6BDcB6bFE51558EA465B063486B70dc9f"

# Load the Valid Proof (Hex)
export PROOF=$(cat proof_extracted.hex)
```

### Submit "Mark as Predator" Transaction
```bash
cast send --rpc-url $RPC_URL --private-key $PRIVATE_KEY $AGENT_NFT \
  "markAsPredatorWithProof(uint256,address,bool,bytes,uint256[])" \
  0 \
  $PREDATOR \
  true \
  $PROOF \
  "[0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593effffca2, 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593effffd86, 0x0000000000000000000000000000000000000000000000000000000000001eb5, 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593effff08f, 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593effffead, 0x0000000000000000000000000000000000000000000000000000000000001031, 0x00000000000000000000000000000000000000000000000000000000000005b1]"
```

## 7. Verify Result

Check if the contract successfully updated the predator status.

```bash
cast call --rpc-url $RPC_URL $HOOK "isPredator(address)(bool)" $PREDATOR
```

**Expected Output:**
```
true
```
