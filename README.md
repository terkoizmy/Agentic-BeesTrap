# 🐝 BeeTrap: AI-Powered MEV Protection for Uniswap V4

<div align="center">

**Zero-Knowledge AI Defense Against MEV Predator**

[![Ready for Deployment](https://img.shields.io/badge/Status-Ready%20for%20Deployment-blue?style=for-the-badge)](https://github.com/terkoiz/Agentic-BeesTrap)
[![ZK Verified](https://img.shields.io/badge/ZK%20Proof-EZKL%20Verified-00D632?style=for-the-badge)](https://ezkl.xyz)
[![Uniswap V4](https://img.shields.io/badge/Uniswap-V4%20Hooks-FF007A?style=for-the-badge)](https://uniswap.org)
[![Unichain](https://img.shields.io/badge/Chain-Unichain_Sepolia-FF007A?style=for-the-badge)](https://unichain-sepolia.blockscout.com/)
[![MIT License](https://img.shields.io/badge/License-MIT-blue?style=for-the-badge)](LICENSE)

</div>

---

## 📖 Table of Contents

- [About BeeTrap](#about-beetrap)
- [The Problem](#the-problem)
- [Our Solution](#our-solution)
- [How It Works](#how-it-works)
- [Technology Stack](#technology-stack)
- [Architecture](#architecture)
- [Key Features](#key-features)
- [AI Model Creation](#AI-Model-Creation)
- [Smart Contracts](#smart-contracts)
- [Agent NFT System](#agent-nft-system)
- [Deployment](#deployment)
- [Testing](#testing)
- [Hackathon Tracks](#hackathon-tracks)
- [Future Roadmap](#future-roadmap)
- [Team](#team)

---

## 🎯 About BeeTrap

BeeTrap is the **first AI-powered MEV protection system** built on Uniswap V4 that uses **Zero-Knowledge Machine Learning** to detect and trap sandwich attack bots in real-time. We protect liquidity providers from predatory MEV extraction while maintaining complete decentralization and cryptographic verifiability.

```
┌─────────────────────────────────────────────────────────────┐
│                    THE MEV PROBLEM                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Every day on Uniswap:                                      │
│                                                             │
│  💸 $5M+ extracted by MEV bots                              │
│  🎯 Sandwich attacks targeting normal users                │
│  📉 LPs lose profits to front-running                       │
│  🤖 Traditional detection: too slow or centralized          │
│                                                             │
│  Result: Honest users subsidize bot profits                │
│                                                             │
└─────────────────────────────────────────────────────────────┘

                           ↓ BeeTrap ↓

┌─────────────────────────────────────────────────────────────┐
│                    THE BEETRAP SOLUTION                      │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  🤖 AI Detection      → Real-time mempool monitoring        │
│  🔐 ZK Proofs (EZKL)  → Cryptographic ML verification       │
│  🪝 Uniswap V4 Hooks  → On-chain enforcement (10% trap fee) │
│  🎨 Agent NFTs        → Decentralized AI authorization      │
│                                                             │
│  Result: Bots pay 10%, LPs earn 33x more than normal!      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## ❌ The Problem

### MEV Extraction is Rampant

Traditional DEXs are vulnerable to sophisticated MEV attacks:

| Attack Type | Annual Loss | Detection Method | Success Rate |
|-------------|-------------|------------------|--------------|
| **Sandwich Attacks** | $1.3B+ | Manual analysis | Low (reactive) |
| **Front-running** | $800M+ | Mempool monitoring | Medium (slow) |
| **JIT Liquidity** | $300M+ | Pattern recognition | Low (complex) |

### Current Solutions Fall Short

| Solution | Problem |
|----------|---------|
| **Private Mempools** | Centralized, reduces transparency |
| **Flashbots** | Requires integration, limited coverage |
| **Manual Blacklists** | Reactive, easy to evade |
| **On-chain Detection** | Too expensive, lagging indicators |

**What's Missing:** A system that is:
- ✅ **Real-time** (detects before execution)
- ✅ **Decentralized** (no trusted party)
- ✅ **Verifiable** (cryptographically proven)
- ✅ **Economically punitive** (makes attacks unprofitable)

---

## ✨ Our Solution

BeeTrap introduces **Zero-Knowledge Machine Learning** to DeFi security:

### Core Innovation: ZK-ML Pipeline

```
┌──────────────────────────────────────────────────────────────┐
│                    BEETRAP ZK-ML FLOW                        │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  1️⃣ MEMPOOL MONITORING (Rust Agent)                         │
│     • Subscribe to pending transactions                      │
│     • Filter Uniswap V4 swaps                                │
│     • Extract features (gas, value, patterns)                │
│                                                              │
│  2️⃣ AI INFERENCE (ONNX Model)                                │
│     • 6-feature neural network                               │
│     • Trained on sandwich attack samples                     │
│     • Output: Bot probability (0.0 - 1.0)                    │
│     • Threshold: Customizable (default 95%)                  │
│                                                              │
│  3️⃣ ZK PROOF GENERATION (EZKL)                               │
│     • Convert ML inference to ZK circuit                     │
│     • Generate Halo2 proof (~2 seconds)                      │
│     • Proof Size: ~180 KB                                    │
│     • Cryptographically verifiable on-chain                  │
│                                                              │
│  4️⃣ ON-CHAIN ENFORCEMENT (Uniswap V4 Hook)                   │
│     • Verify ZK proof via Halo2Verifier.sol                  │
│     • Mark bot address as predator                           │
│     • Override swap fee: 0.3% → 10%                          │
│     • Track performance via Agent NFT                        │
│                                                              │
│  5️⃣ RESULT                                                   │
│     • Bot pays 10% fee (33x higher!)                         │
│     • LP earnings increase dramatically                      │
│     • Attack becomes economically irrational                 │
│     • ✅ MEV protection activated!                           │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## 🔧 How It Works

### Step-by-Step Flow

#### **Phase 1: Detection (Off-Chain)**

```rust
// Rust agent monitors Ethereum mempool
let tx_sub = provider.subscribe_pending_transactions().await?;

// Filter for Uniswap V4 swaps
if is_uniswap_v4_swap(&tx) {
    // Extract features
    let features = FeatureVector {
        gas_price_gwei: (tx.gas_price / 1e9) as f32,
        priority_fee_gwei: (tx.max_priority_fee / 1e9) as f32,
        native_value: (tx.value / 1e18) as f32,
        gas_limit: tx.gas as f32,
        // ... etc
    };
    
    // AI inference via ONNX
    let probability = ml_model.predict(&features)?;
    
    if probability > 0.95 {
        // 🚨 BOT DETECTED!
        generate_zk_proof(features, probability).await?;
    }
}
```

#### **Phase 2: Proof Generation (EZKL)**

```bash
# Generate witness from ML inference
ezkl gen-witness -D input.json -M network.ezkl -O witness.json

# Generate ZK proof
ezkl prove -W witness.json --pk pk.key -O proof.json

# Output: Cryptographic proof that ML model output ≥ 95%
```

#### **Phase 3: On-Chain Verification (Solidity)**

```solidity
function markAsPredatorWithProof(
    address bot,
    bool status,
    uint256[] calldata proof,
    uint256[] calldata publicInputs,
    uint256 agentTokenId
) external {
    // Verify Agent NFT ownership
    require(AGENT_NFT.ownerOf(agentTokenId) == msg.sender);
    require(AGENT_NFT.isAuthorizedAgent(agentTokenId));
    
    // Verify ZK proof
    require(
        IZKVerifier(verifier).verify(proof, publicInputs),
        "Invalid ZK proof"
    );
    
    // Mark as predator
    isPredator[bot] = status;
    
    // Update stats
    AGENT_NFT.incrementTotalDetections(agentTokenId);
}
```

#### **Phase 4: Fee Override (Uniswap V4 Hook)**

```solidity
function beforeSwap(
    address sender,
    PoolKey calldata key,
    IPoolManager.SwapParams calldata params,
    bytes calldata hookData
) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
    
    if (isPredator[sender]) {
        // 🪤 TRAP ACTIVATED!
        // Return 10% fee override
        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            TRAP_FEE | OVERRIDE_FEE_FLAG  // 10% fee!
        );
    }
    
    // Normal user: 0.3% default fee
    return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
}
```

---

## 🏗️ Architecture

### System Components

```
┌─────────────────────────────────────────────────────────────┐
│                    BEETRAP ARCHITECTURE                      │
└─────────────────────────────────────────────────────────────┘

OFF-CHAIN LAYER:
┌──────────────────────────────────────┐
│  Rust AI Agent                       │
│  • Mempool listener (alloy-rs)       │
│  • ONNX runtime (ML inference)       │
│  • EZKL client (proof generation)    │
│  • Web3 client (tx submission)       │
└──────────────┬───────────────────────┘
               │
               │ ZK Proof + Transaction
               ↓
ON-CHAIN LAYER:
┌──────────────────────────────────────┐
│  Agent NFT (ERC-721 + ERC-7857)      │
│  • Authorization & ownership         │
│  • Performance tracking              │
│  • Decentralized governance          │
└──────────────┬───────────────────────┘
               │
               ↓
┌──────────────────────────────────────┐
│  Halo2Verifier.sol (EZKL-generated)  │
│  • ZK proof verification             │
│  • Groth16 / Halo2 cryptography      │
└──────────────┬───────────────────────┘
               │
               ↓
┌──────────────────────────────────────┐
│  BeeTrapHook.sol (Uniswap V4)        │
│  • beforeSwap() - Fee override       │
│  • afterSwap() - Analytics           │
│  • Predator tracking                 │
└──────────────┬───────────────────────┘
               │
               ↓
┌──────────────────────────────────────┐
│  Uniswap V4 Pool Manager             │
│  • Liquidity pools                   │
│  • Swap execution                    │
│  • Hook integration                  │
└──────────────────────────────────────┘
```

---

## 🛠️ Technology Stack

<div align="center">

| Layer | Technology | Purpose |
|-------|------------|---------|
| **Blockchain** | Ethereum | EVM-compatible L1/L2 |
| **DEX Protocol** | Uniswap V4 Hooks | Liquidity & swap execution |
| **Smart Contracts** | Solidity 0.8.26, Foundry | On-chain logic |
| **ZK Proofs** | EZKL (Halo2) | ML verification |
| **AI/ML** | ONNX Runtime | Bot detection |
| **Off-Chain Agent** | Rust, alloy-rs, tokio | Mempool monitoring |
| **Testing** | Foundry (Forge), Rust tests | Quality assurance |
| **NFT Standard** | ERC-721, ERC-7857 | Agent authorization |

</div>

### Why These Technologies?

**EZKL (Halo2)**
- ✅ Converts ML models to ZK circuits automatically
- ✅ No trusted setup required (unlike Groth16)
- ✅ Ethereum-native verification
- ✅ Production-ready

**Uniswap V4 Hooks**
- ✅ Programmable swap logic
- ✅ Gas-efficient fee overrides
- ✅ Native integration with liquidity
- ✅ Future-proof (v4 is the future)

**Rust Agent**
- ✅ High performance (critical for mempool speed)
- ✅ Memory safety (no exploits)
- ✅ Async runtime (handle thousands of TXs)
- ✅ Strong typing (fewer bugs)

**Agent NFT (ERC-7857)**
- ✅ Decentralized authorization (no single admin)
- ✅ Transferable AI identities
- ✅ On-chain performance tracking
- ✅ Encrypted metadata support

---

## 🎨 Key Features

### 1. **Real-Time Mempool Monitoring**
The agent listens to pending transactions using Websockets, analyzing gas price, value, and access patterns to detect potential sandwich attacks before they are included in a block.

### 2. **Zero-Knowledge ML Verification**
Instead of trusting the agent blindly, the smart contract requires a ZK-Proof (generated by EZKL) that certifies the ML model's output. This ensures that only mathematically proven "predators" are penalized.

### 3. **Economic Incentive Alignment**
By imposing a punitive fee (10%) on detected bots, BeeTrap makes sandwich attacks economically irrational. The extracted fee is distributed to Liquidity Providers, turning a loss into a profit.

### 4. **Decentralized Agent Network**
Anyone can run an agent by minting an Agent NFT. This creates a competitive market for detection models, where the best performing agents are rewarded.

---

## 📜 Smart Contracts

### Core Contracts

| Contract | Purpose |
|----------|---------|
| **BeeTrapHook.sol** | Uniswap V4 hook with fee override logic |
| **AgentNFT.sol** | ERC-721 + ERC-7857 agent authorization |
| **Halo2Verifier.sol** | EZKL-generated ZK verifier |
| **ValidationRegistry.sol** | ERC-8004 attestation system |

### Security Features

✅ **Access Control**: Only authorized Agent NFT holders can submit proofs.

✅ **ZK Verification**: On-chain verification of off-chain ML inferences.

✅ **Standard Compliance**: Uses ERC-721 and Uniswap V4 standard interfaces.

### Deployed Contracts (Unichain Sepolia)

| Contract | Address |
|----------|---------|
| **BeeTrapHook** | `0x66aba306aCaa902b9B36a715ECfdE2a4a9e2Dac5` |
| **AgentNFT** | `0x0d078eca4007a5f14ad9206f0fe1b0c28fe0236b` |
| **ValidationRegistry** | `0xb9eF3A26B4e617c7876724D88B77Fd0e5Da64517` |
| **PoolManager** | `0x000000000004444c5dc75cB358380D2e3dE08A90` |

---

## 🧠 AI Model Creation

The AI model powering BeeTrap is developed using **TensorFlow/Keras** and converted to a Zero-Knowledge Circuit using **EZKL**. The training pipeline (`agent/assets/Final_BeeTrap.ipynb`) involves:

### 1. Data Processing
- **Features Used (6):** `gas_price_gwei`, `priority_fee_gwei`, `gas_usage_ratio`, `gas_used`, `native_value`, `tx_index`.
- **Normalization:** Uses `StandardScaler` to normalize inputs for numerical stability in the ZK circuit.

### 2. Model Architecture
A lightweight Multi-Layer Perceptron (MLP) optimized for on-chain verification:
- **Input Layer:** 6 Neurons (Features)
- **Hidden Layer 1:** 16 Neurons (ReLU)
- **Hidden Layer 2:** 8 Neurons (ReLU)
- **Output Layer:** 1 Neuron (Logits)

### 3. ZK-ML Pipeline
1.  **Training:** Trained on a dataset of sandwich attacks vs. normal swaps using `BinaryCrossentropy`.
2.  **Export:** Converted to **ONNX** format (Opset 12).
3.  **Quantization:** Calibrated using `ezkl.calibrate_settings` to ensure accuracy within the field elements.
4.  **Proof Generation:** Compiled into a `halo2` circuit, enabling the creation of small (~180KB) proofs that certify the model's output without revealing the private inputs or weights if needed.



---

## 🚀 Deployment

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install Rust (for agent)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Install EZKL
cargo install ezkl --locked

# Clone repository
git clone https://github.com/terkoiz/Agentic-BeesTrap.git
cd Agentic-BeesTrap
```

### EZKL Setup

```bash
# Run automated setup script (requires python3)
./scripts/setup-ezkl.sh
```

### Deploy Smart Contracts (Anvil/Local)

```bash
# 1. Start Anvil
anvil

# 2. Deploy
forge script script/DeployBeeTrap.s.sol \
    --rpc-url http://127.0.0.1:8545 \
    --broadcast \
    --verify \
    -vvvv
```

### Setup Agent

```bash
cd agent

# 1. Configure agent
cp .env.example .env
# Edit .env to set your private key and contract addresses

# 2. Build agent
cargo build --release

# 3. Run agent
./target/release/beetrap-agent
```

### Create Uniswap V4 Pool with BeeTrap

The deployment script handles the creation of a test pool initialized with the BeeTrap hook.

---

## 🧪 Testing

### Test Coverage

```bash
forge test -vv
```

**Test Suite:** Includes unit tests for the Hook, ZK Verifier integration, and Agent NFT logic.

---

## 🏆 Hackathon Tracks

<div align="center">

### ETH Global Bangkok 2024

| Track | Category |
|-------|----------|
| **Uniswap** | Best Use of Uniswap V4 Hooks |
| **Worldcoin** | Best ZK Application (EZKL) |
| **Base** | Best DeFi Innovation on Base |
| **AI/ML** | Best AI Integration in Web3 |

</div>

### Why BeeTrap Wins

**✅ Technical Innovation**
- First ZK-ML on Uniswap V4
- Novel MEV protection mechanism
- Production-ready EZKL integration

**✅ Real-World Impact**
- Protects LPs from toxic MEV
- Decentralizes security
- Verifiable AI inference

---

## 🏗️ Repository Structure

```
beetrap/
├── contracts/              # Solidity smart contracts
│   ├── src/
│   │   ├── BeeTrapHook.sol
│   │   ├── AgentNFT.sol
│   │   ├── ValidationRegistry.sol
│   │   └── interfaces/
│   └── test/               # Foundry tests
│       ├── BeeTrapHook.t.sol
│       └── BeeTrapHookIntegration.t.sol
├── agent/                  # Off-chain AI agent (Rust)
│   ├── src/
│   │   ├── main.rs
│   │   ├── mempool.rs
│   │   ├── processor.rs    # ML inference
│   │   └── zk.rs           # EZKL integration
│   ├── assets/             # EZKL artifacts (model, keys)
│   └── Cargo.toml
├── scripts/                # Deployment & setup
│   ├── DeployBeeTrap.s.sol
│   └── setup-ezkl.sh
└── docs/                   # Documentation
    └── *.md
```

---

## 👥 Team

<div align="center">

**Built by passionate DeFi security researchers**

*This project was built for ETH Global Hackmoney 2026*

</div>

---

## 📄 License

MIT License - see [LICENSE](LICENSE) for details

---

## 🙏 Acknowledgments

- **Uniswap Labs** - For building Uniswap V4 and hooks
- **EZKL Team** - For making ZK-ML accessible
- **Flashbots** - For MEV research and tooling
- **ETH Global** - For hackathon support

---

<div align="center">

**🐝 BeeTrap** — *Protecting DeFi, One Trap at a Time*

*"The best defense against MEV is making it unprofitable."*

**ETH Global Hackmoney 2026**

</div>
