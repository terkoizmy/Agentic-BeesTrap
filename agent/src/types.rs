//! # Shared Types
//!
//! Common types used across the BeeTrap Sentinel agent.

use chrono::{DateTime, Utc};
use eyre::Result;
use std::fmt;
use std::time::{Duration, Instant};

// ═══════════════════════════════════════════════════════════════════════════
//                          CONFIGURATION
// ═══════════════════════════════════════════════════════════════════════════

/// Main configuration for the BeeTrap Sentinel
#[derive(Debug, Clone)]
pub struct Config {
    /// WebSocket RPC URL for mempool streaming
    pub rpc_url: String,
    /// WebSocket RPC URL for execution/transactions (e.g. Anvil)
    pub execution_rpc_url: String,
    /// Chain ID (1=Ethereum, 8453=Base, 42161=Arbitrum)
    pub chain_id: u64,
    /// Private key for signing (hex, with or without 0x prefix)
    pub private_key: String,
    /// Uniswap v4 PoolManager address
    pub pool_manager_address: String,
    /// Uniswap Universal Router address
    pub universal_router_address: String,
    /// BeeTrapHook contract address
    pub hook_address: String,
    /// Agent NFT contract address
    pub agent_nft_address: String,
    /// Agent NFT ID
    pub agent_nft_id: u64,
    /// Path to ONNX model file
    pub model_path: String,
    /// Confidence threshold for detection (0.0 - 1.0)
    pub confidence_threshold: f32,
    /// Run in demo mode with mock brain and mock data
    pub demo_mode: bool,
    /// Use mock transaction data instead of real RPC (for testing real ONNX)
    pub use_mock_data: bool,
}

impl Config {
    /// Load configuration from environment variables
    pub fn from_env() -> Result<Self> {
        dotenvy::dotenv().ok();

        let rpc_url =
            std::env::var("RPC_URL").unwrap_or_else(|_| "ws://localhost:8545".to_string());
        let execution_rpc_url = std::env::var("EXECUTION_RPC_URL").unwrap_or(rpc_url.clone());

        Ok(Self {
            rpc_url,
            execution_rpc_url,
            chain_id: std::env::var("CHAIN_ID")
                .unwrap_or_else(|_| "31337".to_string())
                .parse()
                .unwrap_or(31337),
            private_key: std::env::var("PRIVATE_KEY")
                .unwrap_or_else(|_| {
                    "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80".to_string()
                })
                .trim_start_matches("0x")
                .to_string(),
            pool_manager_address: std::env::var("POOL_MANAGER_ADDRESS").unwrap_or_default(),
            universal_router_address: std::env::var("UNIVERSAL_ROUTER_ADDRESS").unwrap_or_default(),
            hook_address: std::env::var("HOOK_ADDRESS").unwrap_or_default(),
            agent_nft_address: std::env::var("AGENT_NFT_ADDRESS").unwrap_or_default(),
            agent_nft_id: std::env::var("AGENT_NFT_ID")
                .unwrap_or_else(|_| "0".to_string())
                .parse()
                .unwrap_or(0),
            model_path: std::env::var("MODEL_PATH")
                .unwrap_or_else(|_| "agent/assets/network.onnx".to_string()),
            confidence_threshold: std::env::var("CONFIDENCE_THRESHOLD")
                .unwrap_or_else(|_| "0.8".to_string())
                .parse()
                .unwrap_or(0.8),
            demo_mode: std::env::var("DEMO_MODE")
                .map(|v| v == "1" || v.to_lowercase() == "true")
                .unwrap_or(false),
            use_mock_data: std::env::var("USE_MOCK_DATA")
                .map(|v| v == "1" || v.to_lowercase() == "true")
                .unwrap_or(false),
        })
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//                          TRANSACTION TYPES
// ═══════════════════════════════════════════════════════════════════════════

/// A pending transaction from the mempool
#[derive(Debug, Clone)]
pub struct PendingTransaction {
    /// Transaction hash
    pub hash: String,
    /// Sender address
    pub from: String,
    /// Recipient address (None for contract creation)
    pub to: Option<String>,
    /// Value in wei
    pub value: u128,
    /// Gas price in wei (Legacy)
    pub gas_price: Option<u128>,
    /// Max fee per gas in wei (EIP-1559)
    pub max_fee_per_gas: Option<u128>,
    /// Max priority fee per gas in wei (EIP-1559)
    pub max_priority_fee_per_gas: Option<u128>,
    /// Priority fee in wei (Legacy/Computed) - kept for backward compat if needed, but we'll prefer explicit fields
    pub priority_fee: u128,
    /// Gas limit
    pub gas_limit: u64,
    /// Transaction input data
    pub input: Vec<u8>,
    /// When the transaction was received
    pub received_at: Instant,
    /// Chain ID
    pub chain_id: u64,
}

/// Summarized transaction for UI display
#[derive(Debug, Clone)]
pub struct TransactionSummary {
    pub hash: String, // Full hash for linking
    pub short_hash: String,
    pub from_short: String,
    pub to_short: String,
    pub value_eth: f64,
    pub gas_gwei: f64,
    pub suspicious: bool,
    pub probability: Option<f32>, // Added: Store AI Score
}

/// Feature vector extracted from a transaction for AI inference
/// Must match Python training features exactly:
/// f0: tx_index
/// f1: gas_price_gwei
/// f2: priority_fee_gwei
/// f3: gas_used
/// f4: native_value
/// f5: gas_usage_ratio
#[derive(Debug, Clone)]
pub struct FeatureVector {
    pub tx_index: f32,
    pub gas_price_gwei: f32,
    pub priority_fee_gwei: f32,
    pub gas_used: f32,
    pub native_value: f32,
    pub gas_usage_ratio: f32,
}

impl FeatureVector {
    /// Convert to array for ONNX input (order must match training!)
    pub fn to_array(&self) -> [f32; 6] {
        [
            self.gas_price_gwei,
            self.priority_fee_gwei,
            self.gas_usage_ratio,
            self.gas_used,
            self.native_value,
            self.tx_index,
        ]
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//                          DETECTION TYPES
// ═══════════════════════════════════════════════════════════════════════════

/// A detected MEV bot
#[derive(Debug, Clone)]
pub struct Detection {
    /// Suspected bot address
    pub bot_address: String,
    /// Transaction hash that triggered detection
    pub tx_hash: String,
    /// AI confidence score (0.0 - 1.0)
    pub confidence: f32,
    /// When detected
    pub detected_at: DateTime<Utc>,
    /// Inference latency
    pub latency: Duration,
    /// Reason for detection
    pub reason: DetectionReason,
}

/// Reason for MEV detection
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DetectionReason {
    HighGasFrontrun,
    SandwichPattern,
    GenericMEV,
    KnownBotPattern,
}

impl fmt::Display for DetectionReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::HighGasFrontrun => write!(f, "High Gas Frontrun"),
            Self::SandwichPattern => write!(f, "Sandwich Pattern"),
            Self::GenericMEV => write!(f, "Generic MEV"),
            Self::KnownBotPattern => write!(f, "Known Bot"),
        }
    }
}

/// A signed detection ready for on-chain submission
#[derive(Debug, Clone)]
pub struct SignedDetection {
    pub detection: Detection,
    pub signature: Vec<u8>,
    pub model_hash: [u8; 32],
}

// ═══════════════════════════════════════════════════════════════════════════
//                          NETWORK STATUS
// ═══════════════════════════════════════════════════════════════════════════

/// Network connection status
#[derive(Debug, Clone, Default)]
pub struct NetworkStatus {
    pub chain: String,
    pub chain_id: u64,
    pub gas_price: u128,
    pub connected: bool,
    pub block_number: u64,
}

/// Sentinel statistics
#[derive(Debug, Clone, Default)]
pub struct SentinelStats {
    pub total_scanned: u64,
    pub total_detected: u64,
    pub total_trapped: u64, // AKA blocked
    pub uptime_secs: u64,
    pub zk_proofs_generated: u64, // Add this as well
    // Economic Impact
    pub eth_saved: f64,
    pub gas_saved: u128,
    pub efficiency_boost: f32,
    pub history_saved: Vec<u64>,
}

// ═══════════════════════════════════════════════════════════════════════════
//                          CHANNEL MESSAGES
// ═══════════════════════════════════════════════════════════════════════════

/// Messages sent to the executor
#[derive(Debug)]
pub enum ExecutorMessage {
    ExecuteTrap(Detection),
    Shutdown,
}

/// Messages sent to the UI
#[derive(Debug)]
pub enum UiMessage {
    NewTransaction(TransactionSummary),
    NewDetection(Detection),
    NetworkUpdate(NetworkStatus),
    StatsUpdate(SentinelStats),
    LatencyUpdate(u64),
    ConfidenceUpdate(String, f32), // Changed: Hash + Score
    ProcessingUpdate(ProcessingStage),
    Log(String), // New: Operation Log
}

/// Helper enum for ZK processing stages state updates
#[derive(Debug, Clone)]
pub enum ProcessingStage {
    Idle,
    NormalizingData(String), // tx_hash
    GeneratingWitness(String),
    CreatingZKProof(String),
    ProofComplete(String),
    Error(String, String),
}

// ═══════════════════════════════════════════════════════════════════════════
//                          APPLICATION STATE
// ═══════════════════════════════════════════════════════════════════════════

/// Application state for the TUI
#[derive(Debug, Default)]
pub struct AppState {
    pub network: NetworkStatus,
    pub stats: SentinelStats,
    pub recent_transactions: Vec<TransactionSummary>,
    pub recent_detections: Vec<Detection>,
    pub last_confidence: f32,
    pub latency_ms: u64,
    pub should_quit: bool,
    pub table_area: (u16, u16, u16, u16), // x, y, width, height (Avoiding ratatui dep here for now)
    pub ai_insight_area: (u16, u16, u16, u16),
    pub logs_area: (u16, u16, u16, u16),
    pub logs: Vec<String>, // New: Operation Logs
    pub status_message: Option<(String, std::time::Instant)>, // UI Feedback (Message, Time)
}
