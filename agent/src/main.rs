use crate::{
    indexer::spawn_mempool_listener,
    processor::spawn_processor,
    types::{Config, PendingTransaction, UiMessage},
};
use eyre::Result;
use tokio::sync::mpsc;
use tracing::{info, Level};
use tracing_subscriber::FmtSubscriber;

pub mod indexer;
pub mod network;
pub mod processor;
pub mod types;
pub mod ui; // Add UI module

#[tokio::main]
async fn main() -> Result<()> {
    // 1. Initialize Logging (File only, to avoid TUI conflict)
    // TUI takes over stdout. We should log to file.
    let file_appender = tracing_appender::rolling::daily("logs", "sentinel.log");
    let (non_blocking, _guard) = tracing_appender::non_blocking(file_appender);

    let subscriber = FmtSubscriber::builder()
        .with_max_level(Level::INFO)
        .with_writer(non_blocking)
        .with_ansi(false) // Disable colors for file log
        .finish();

    tracing::subscriber::set_global_default(subscriber)?;

    // 2. Load Config
    let config = Config::from_env()?;
    info!("Starting BeeTrap Sentinel...");
    info!("RPC URL: {}", config.rpc_url);
    info!("Target Pool Manager: {}", config.pool_manager_address);

    // 3. Setup Channels
    // Channel from Indexer -> Processor (Bounded to 100 to prevent OOM)
    let (tx_sender, tx_receiver) = mpsc::channel::<PendingTransaction>(100);

    // Channel from Processor/Indexer -> UI (TUI)
    let (ui_sender, ui_receiver) = mpsc::unbounded_channel::<UiMessage>();

    // 4. Setup Network Client (Signer)
    info!(
        "Initializing Sentinel Client (Executor -> {})...",
        config.execution_rpc_url
    );
    // We hack the config temporarily or update build_client to use execution_rpc_url
    // Actually network::build_client uses config.rpc_url. We should fix network.rs too or swap it here.
    // Let's swap it here for simplicity:
    let mut execution_config = config.clone();
    execution_config.rpc_url = config.execution_rpc_url.clone();
    let client = network::build_client(&execution_config).await?;
    let client = std::sync::Arc::new(client);

    // 4. Spawn Indexer
    let rpc_url = config.rpc_url.clone(); // MAINNET: Listen for traffic
    let target_address = config.pool_manager_address.clone();
    let router_address = config.universal_router_address.clone();
    let tx_sender_clone = tx_sender.clone();
    let ui_sender_clone = ui_sender.clone();
    let indexer_handle = tokio::spawn(async move {
        if let Err(e) = spawn_mempool_listener(
            rpc_url,
            target_address,
            router_address,
            tx_sender_clone,
            ui_sender_clone,
        )
        .await
        {
            tracing::error!("CRITICAL: Mempool Listener failed: {:?}", e);
        }
    });

    // 5. Spawn Processor
    // Processor needs UI sender to report stats/detections
    let model_path = config.model_path.clone();
    let rpc_url_processor = config.execution_rpc_url.clone(); // UNICHAIN: Execute/Estimate

    let confidence_threshold = config.confidence_threshold;

    let processor_handle = tokio::spawn(async move {
        if let Err(e) = spawn_processor(
            tx_receiver,
            ui_sender,
            model_path,
            rpc_url_processor,
            confidence_threshold,
            client,
        )
        .await
        {
            tracing::error!("CRITICAL: Processor failed to start: {:?}", e);
        }
    });

    // 6. Run TUI (Blocking Main Thread)
    // 6. Run TUI or Headless
    if std::env::var("HEADLESS").is_ok() {
        info!("Running in HEADLESS mode. Logs in logs/sentinel.log");
        // Drain UI receiver to prevent memory leak and log important events
        let mut rx = ui_receiver;
        while let Some(msg) = rx.recv().await {
            match msg {
                UiMessage::Log(s) => info!("[UI LOG] {}", s),
                UiMessage::NewDetection(d) => info!(
                    "[DETECTED] Bot: {} (Confidence: {:.4})",
                    d.bot_address, d.confidence
                ),
                _ => {}
            }
        }
    } else {
        // Must run in current thread to handle terminal
        info!("Launching TUI...");
        if let Err(e) = ui::run_tui(ui_receiver, config.confidence_threshold).await {
            eprintln!("TUI Error: {}", e);
        }
    }

    // When TUI exits (User presses 'q'), we shut down.
    // We can abort background tasks
    indexer_handle.abort();
    processor_handle.abort();

    Ok(())
}
