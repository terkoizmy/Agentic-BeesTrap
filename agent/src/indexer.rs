use crate::types::{PendingTransaction, TransactionSummary, UiMessage};
use alloy::{
    consensus::Transaction as TransactionTrait,
    primitives::Address,
    providers::{Provider, ProviderBuilder, WsConnect},
    rpc::types::Transaction,
};
use eyre::Result;
use futures::StreamExt;
use std::str::FromStr;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc::{self, Sender, UnboundedSender};
use tokio::sync::Semaphore;
use tokio::time::sleep;
use tracing::{error, info, warn};

/// Uniswap V4 Pool Manager Address
pub const POOL_MANAGER_ADDRESS: &str = "0x000000000004444c5dc75cB358380D2e3dE08A90";

/// Spawns the mempool listener with automatic reconnection logic
pub async fn spawn_mempool_listener(
    p2p_wss_url: String,
    pool_manager_str: String,
    router_str: String,
    tx_sender: Sender<PendingTransaction>,
    ui_sender: UnboundedSender<UiMessage>,
) -> Result<()> {
    let pool_manager = Address::from_str(&pool_manager_str)?;
    let router = Address::from_str(&router_str)?;

    info!(target: "sentinel", "Starting Mempool Listener...");
    info!(target: "sentinel", "Target 1 (PoolManager): {}", pool_manager);
    info!(target: "sentinel", "Target 2 (Router): {}", router);

    loop {
        match run_listener_session(&p2p_wss_url, &tx_sender, &ui_sender, pool_manager, router).await
        {
            Ok(_) => {
                warn!("Listener session ended normally. Restarting...");
            }
            Err(e) => {
                error!("Listener session failed: {}. Retrying in 5s...", e);
            }
        }
        sleep(Duration::from_secs(5)).await;
    }
}

async fn run_listener_session(
    wss_url: &str,
    tx_sender: &Sender<PendingTransaction>,
    ui_sender: &UnboundedSender<UiMessage>,
    pool_manager: Address,
    router: Address,
) -> Result<()> {
    // 1. Establish WSS Connection
    let ws = WsConnect::new(wss_url);
    let provider = ProviderBuilder::new().on_ws(ws).await?;

    info!("Connected to Ethereum Node via WSS");

    // Notify UI of connection
    let _ = ui_sender.send(UiMessage::NetworkUpdate(crate::types::NetworkStatus {
        connected: true,
        chain: "Ethereum".to_string(), // Or get from chain_id
        chain_id: 1,                   // Placeholder or fetch
        block_number: 0,               // Will update when block heard
        gas_price: 0,
    }));

    // 2. Subscribe to New Blocks (Heads)
    let block_sub = provider.subscribe_blocks().await?;
    let mut block_stream = block_sub.into_stream();

    // 3. Subscribe to Pending Transactions (Hashes)
    let tx_sub = provider.subscribe_pending_transactions().await?;
    let mut tx_stream = tx_sub.into_stream();

    info!("Subscribed to blocks and pending transactions. Waiting for activity...");

    // 4. Process Streams Conditionally
    // We use tokio::select! to handle both streams concurrently
    let semaphore = Arc::new(Semaphore::new(10)); // Reduced to 10 for safe sampling

    loop {
        tokio::select! {
            Some(header) = block_stream.next() => {
                 let block_num = header.number;
                 let gas_price = header.base_fee_per_gas.unwrap_or(0) as u128;

                 // Update UI
                 let _ = ui_sender.send(UiMessage::NetworkUpdate(crate::types::NetworkStatus {
                    connected: true,
                    chain: "Ethereum".to_string(),
                    chain_id: 1,
                    block_number: block_num,
                    gas_price: gas_price,
                 }));
            }
            Some(tx_hash) = tx_stream.next() => {
                let provider_clone = provider.clone();
                let tx_sender_clone = tx_sender.clone();
                let ui_sender_clone = ui_sender.clone();
                let tx_hash_str = tx_hash.to_string();

                let permit = if let Ok(p) = semaphore.clone().try_acquire_owned() {
                    p
                } else {
                    // Backpressure: Skip or buffer? MPSC mempool is ephemeral.
                    // Better to skip if overwhelmed than lag behind 5 minutes.
                    // tracing::debug!("Dropped tx {} due to load", tx_hash_str); // Reduce noise
                    continue;
                };

                tokio::spawn(async move {
                    let _permit = permit; // Drop permit when task finishes
                    match provider_clone.get_transaction_by_hash(tx_hash).await {
                        Ok(Some(tx)) => {
                            process_transaction(
                                tx_hash_str,
                                tx,
                                &tx_sender_clone,
                                &ui_sender_clone,
                                pool_manager,
                                router
                            )
                            .await;
                        }
                        Ok(None) => {}
                        Err(e) => {
                            tracing::debug!("Failed to fetch tx {}: {}", tx_hash_str, e);
                        }
                    }
                });
            }
            else => break, // Stream ended
        }
    }

    Ok(())
}

async fn process_transaction(
    tx_hash: String,
    tx: Transaction,
    sender: &Sender<PendingTransaction>, // Bounded Sender
    ui_sender: &UnboundedSender<UiMessage>,
    _pool_manager: Address,
    _router: Address,
) {
    // Use the inner transaction envelope to access fields
    let tx_inner = &tx.inner;

    // Check destination (to)
    let to_addr = tx_inner.to();

    // SAMPLING MODE: Process ANY transaction that we have capacity for (semaphore logic handled upstream)
    // We do NOT filter by address here anymore, relying on upstream sampling to keep load low.

    // Found a target transaction!
    let event = PendingTransaction {
        hash: tx_hash.clone(),
        from: tx.from.to_string(),
        to: to_addr.map(|t| t.to_string()),
        value: tx_inner.value().to_string().parse().unwrap_or(0),
        gas_price: tx_inner.gas_price(),
        max_priority_fee_per_gas: tx_inner.max_priority_fee_per_gas(),
        max_fee_per_gas: Some(tx_inner.max_fee_per_gas()),
        priority_fee: tx_inner.max_priority_fee_per_gas().unwrap_or(0),
        gas_limit: tx_inner.gas_limit(),
        input: tx_inner.input().to_vec(),
        received_at: Instant::now(),
        chain_id: tx_inner.chain_id().unwrap_or(1),
    };

    // Send to UI First to avoid race condition (Processor updating before UI creates entry)
    let summary = TransactionSummary {
        hash: tx_hash.clone(),
        short_hash: format!("{}...", &tx_hash[0..8]),
        from_short: format!("{}...", &event.from[0..6]),
        to_short: format!("{}...", &event.to.as_deref().unwrap_or("Creation")[0..6]),
        value_eth: (event.value as f64) / 1e18,
        gas_gwei: (event.gas_price.unwrap_or(0) as f64) / 1e9,
        suspicious: false,
        probability: None, // Init as None
    };
    let _ = ui_sender.send(UiMessage::NewTransaction(summary));

    // Send to Processor (Blocked if full)
    if let Err(e) = sender.send(event.clone()).await {
        warn!("Failed to send tx to processor (channel closed?): {}", e);
    }
}
