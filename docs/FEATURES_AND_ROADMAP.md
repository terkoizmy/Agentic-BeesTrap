# BeesTrap - Features & Future Roadmap

This document outlines the current state of the BeesTrap project, detailing the implemented features ready for deployment and the roadmap for future enhancements, specifically focusing on Smart Contract integration and Zero-Knowledge (ZK) proofs.

## 🚀 Current Features (Ready)

The core monitoring and detection engine is fully functional with the following capabilities:

### 1. Real-Time Mempool Monitoring
- **WebSocket Integration**: Connects directly to Ethereum nodes via `wss://` to listen for pending transactions in real-time.
- **High-Throughput Processing**: Efficiently handles incoming transaction streams with minimal latency.

### 2. AI Threat Detection Engine
- **ONNX Model Inference**: Utilizes a pre-trained Random Forest model (`random_forest_model.onnx`) to analyze transaction patterns.
- **Probability Scoring**: Assigns a "Predator Probability" score (0-100%) to each transaction indicating the likelihood of it being a malicious bot or attack vector.
- **Configurable Thresholds**: Users can set a `CONFIDENCE_THRESHOLD` (e.g., 0.8) to define what constitutes a "Suspicious" transaction (Red) vs. "Safe" (Green).

### 3. Advanced Terminal UI (TUI)
- **Live Activity Feed**: Displays a scrolling list of recent transactions with color-coded status.
- **AI Deep Insight Panel**:
  - Detailed breakdown of selected transactions.
  - Visual display of the specific "Predator Probability".
  - **Etherscan Link**: Full transaction URL displayed for manual verification and copy-pasting.
- **Operation Logs**: Real-time log of detected threats and system actions (both detected bots and system status).
- **Performance Metrics**: Visualizes network latency and simulated economic impact (ETH Saved, Gas Prevented).

### 4. System Logging & Alerting
- **Operation Logging**: All detected high-risk transactions are logged to `logs/sentinel.log` with timestamps and probability scores.
- **Error Handling**: Robust error handling for network disconnections and model inference issues.

---

## 🗺️ Future Roadmap

The next phase of development focuses on moving from **Detection** to **Active Prevention** and **Verification**.

### 1. Smart Contract Integration (Active Defense)
- **Automated Response**: Upon detecting a high-probability threat (e.g., probability > 95%), the agent will automatically interact with a defense smart contract.
- **Defense Mechanisms**:
  - **Pausing**: Temporarily pausing protocol functionality to prevent drainage in extreme cases.
  - **Blacklisting**: Adding the attacker's address to a blocklist to prevent further interaction.
  - **Front-Running Defense**: Submitting a counter-transaction with higher gas to preempt the attack (e.g., executing a trusted withdrawal or state change before the exploit transaction lands).

### 2. Zero-Knowledge (ZK) Integration
- **Verifiable Inference**: Implementing ZK proofs to cryptographically prove that the AI model's decision (e.g., "This tx is malicious") was generated correctly from the input data without revealing the model's internal weights or sensitive data patterns to the public chain.
- **On-Chain Verification**: Smart contracts can verify the ZK proof on-chain before executing a drastic defense action, ensuring the agent is not acting maliciously or erroneously.

### 3. Comprehensive Testing Framework
- **Integration Tests**: Simulating real-world attack scenarios (e.g., Reentrancy, Flash Loan attacks) on a local testnet (Hardhat/Foundry).
- **Fuzzing**: Stress-testing the AI model with randomized transaction inputs to ensure robustness.
- **End-to-End (E2E) UI Testing**: Automating UI interactions to verify the TUI responsiveness and data accuracy.

---

## 📂 Related Documentation

- **[LOCAL_TESTING.md](./LOCAL_TESTING.md)**: Guide on how to run and test the agent locally using simulated data.
