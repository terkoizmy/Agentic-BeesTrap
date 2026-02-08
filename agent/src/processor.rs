use crate::types::{FeatureVector, PendingTransaction, ProcessingStage, SentinelStats, UiMessage};
use alloy::primitives::{Address, U256};
use alloy::providers::{Provider, ProviderBuilder, WsConnect};
use alloy::pubsub::PubSubFrontend;
use alloy::rpc::types::TransactionRequest;

use eyre::{Result, WrapErr};
use ndarray::Array2;
use ort::session::{builder::GraphOptimizationLevel, Session};
use std::process::Command;
use std::str::FromStr;
use tokio::sync::{
    mpsc::{UnboundedReceiver, UnboundedSender},
    Mutex,
};
use tracing::{error, info, instrument};

// ═══════════════════════════════════════════════════════════════════════════
//                          CONSTANTS (NORMALIZATION)
// ═══════════════════════════════════════════════════════════════════════════

/// Means for feature normalization
/// ORDER: [gas_price_gwei, priority_fee_gwei, gas_usage_ratio, gas_used, native_value, tx_index]
const MEANS: [f32; 6] = [
    0.9686767258720472, // gas_price_gwei
    0.75661699955974,   // priority_fee_gwei
    0.5725549928540364, // gas_usage_ratio
    570146.967,         // gas_used
    0.4807524878626883, // native_value
    54.8847,            // tx_index
];

/// Scales (std dev) for feature normalization
/// ORDER: [gas_price_gwei, priority_fee_gwei, gas_usage_ratio, gas_used, native_value, tx_index]
const SCALES: [f32; 6] = [
    7.238926964973418,   // gas_price_gwei
    7.100118667856041,   // priority_fee_gwei
    0.18967953026975654, // gas_usage_ratio
    871444.9154728459,   // gas_used
    11.583387250982357,  // native_value
    85.2014871109067,    // tx_index
];

// ═══════════════════════════════════════════════════════════════════════════
//                          PROCESSOR LOGIC
// ═══════════════════════════════════════════════════════════════════════════

/// Spawns the processing loop
pub async fn spawn_processor<P>(
    mut rx: tokio::sync::mpsc::Receiver<PendingTransaction>, // Bounded Receiver
    ui_sender: UnboundedSender<UiMessage>,
    model_path: String,
    rpc_url: String,
    confidence_threshold: f32,
    client: std::sync::Arc<crate::network::SentinelClient<P>>,
) -> Result<()>
where
    P: Provider<PubSubFrontend, alloy::network::Ethereum> + Clone + 'static,
{
    info!("Starting AI Processor...");

    // Initialize ONNX Session at startup
    // let model_path = "assets/network.onnx"; // REMOVED hardcode
    let session = Session::builder()?
        .with_optimization_level(GraphOptimizationLevel::Level3)?
        .with_intra_threads(1)?
        .commit_from_file(&model_path)
        .wrap_err_with(|| format!("Failed to load ONNX model from {}", model_path))?;

    // `ort::Session` requires &mut self for run(), so we need a Mutex.
    let session = std::sync::Arc::new(Mutex::new(session));

    // Global Stats Tracker (Thread-Safe)
    let stats = std::sync::Arc::new(Mutex::new(SentinelStats::default()));

    // Create Alloy Provider for Gas Estimation
    let ws = WsConnect::new(rpc_url);
    let provider = ProviderBuilder::new().on_ws(ws).await?;
    let provider = std::sync::Arc::new(provider);

    while let Some(tx) = rx.recv().await {
        let ui_sender = ui_sender.clone();
        let session = session.clone();
        let stats = stats.clone();
        let client = client.clone();
        let provider = provider.clone();

        // Spawn a task for each transaction
        tokio::spawn(async move {
            if let Err(e) = process_transaction(
                tx,
                ui_sender,
                session,
                stats,
                provider,
                confidence_threshold,
                client,
            )
            .await
            {
                error!("Processing failed: {:?}", e);
            }
        });
    }

    Ok(())
}

#[instrument(skip(ui_sender, session, tx, stats, provider, client), fields(hash = %tx.hash))]
async fn process_transaction<P>(
    tx: PendingTransaction,
    ui_sender: UnboundedSender<UiMessage>,
    session: std::sync::Arc<Mutex<Session>>,
    stats: std::sync::Arc<Mutex<SentinelStats>>,
    provider: std::sync::Arc<impl Provider<PubSubFrontend> + 'static>,
    confidence_threshold: f32,
    client: std::sync::Arc<crate::network::SentinelClient<P>>,
) -> Result<()>
where
    P: Provider<PubSubFrontend, alloy::network::Ethereum> + Clone + 'static,
{
    let tx_hash = tx.hash.clone();

    // Update Stats: Scanned
    {
        let mut stats_guard = stats.lock().await;
        stats_guard.total_scanned += 1;
        // Optional: Send update on every scan? Maybe too noisy. Update on intervals or detection.
        // Let's update quietly for now or just assume UI polling? UI is push-based.
        // We can send stats update occasionally, but definitely on detection.
    }

    // 1. EXTRACT FEATURES
    let _ = ui_sender.send(UiMessage::ProcessingUpdate(
        ProcessingStage::NormalizingData(tx_hash.clone()),
    ));

    // Extract features (simulated logic for missing data)
    static TX_COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let current_index = TX_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed) % 150; // Simulate block index 0-149

    // Prepare Transaction Request for Gas Estimation
    let from_addr = Address::from_str(&tx.from).unwrap_or_default();
    let to_addr = tx.to.as_ref().and_then(|t| Address::from_str(t).ok());
    let value_u256 = U256::from(tx.value);

    let mut tx_req = TransactionRequest::default()
        .from(from_addr)
        .value(value_u256)
        .input(tx.input.clone().into());

    if let Some(addr) = to_addr {
        tx_req = tx_req.to(addr);
    }

    // Estimate Gas
    let estimated_gas_used = match provider.estimate_gas(&tx_req).await {
        Ok(gas) => gas as f32,
        Err(_e) => {
            // warn!("Gas estimation failed for {}: {:?}", tx_hash, _e);
            // Fallback to limit or simple ratio
            tx.gas_limit as f32 * 0.7 // Assume 70% usage if estimation fails
        }
    };

    let simulated_gas_ratio = estimated_gas_used / (tx.gas_limit as f32 + 1.0); // Simple ratio

    let raw_features = FeatureVector {
        tx_index: current_index as f32,
        gas_price_gwei: (tx.gas_price.unwrap_or(0) as f32) / 1e9,
        priority_fee_gwei: (tx.priority_fee as f32) / 1e9,
        gas_used: estimated_gas_used,
        native_value: (tx.value as f32) / 1e18,
        gas_usage_ratio: simulated_gas_ratio,
    };

    info!("Raw Features [{}]: {:?}", tx_hash, raw_features);

    let normalized_features = normalize_features(&raw_features);
    info!("Normalized [{}]: {:?}", tx_hash, normalized_features);

    // 2. RUN INFERENCE
    // Input shape: [1, 6] - Model expects 6 features.
    let input_vec = normalized_features.to_vec();
    // input_vec.push(0.0); // Padding removed

    let input_tensor = Array2::from_shape_vec((1, 6), input_vec)?;

    // Lock session for inference
    let logit = {
        let mut session_guard = session.lock().await;
        // Convert to Value
        let input_value = ort::value::Value::from_array(input_tensor.into_dyn())?;

        // Dynamically get the first input name
        let input_name = session_guard.inputs()[0].name().to_string();
        let inputs = ort::inputs![
            input_name => input_value,
        ];

        // Dynamically get the first output name
        // Log all outputs for debugging
        for (i, output) in session_guard.outputs().iter().enumerate() {
            info!("Output {}: {:?}", i, output);
        }

        let outputs = session_guard.run(inputs)?;

        // Strategy:
        // 1. If we have >1 output, assume index 1 is probabilities [prob_0, prob_1].
        // 2. If index 1 gives valid f32, use it.
        // 3. Fallback to index 0 (Label), return 0.0 or 1.0.

        let val = if outputs.len() >= 2 {
            if let Ok(tensor) = outputs[1].try_extract_tensor::<f32>() {
                if tensor.1.len() >= 2 {
                    tensor.1[1] // Return Class 1 probability
                } else {
                    // unexpected shape
                    if let Ok(t0) = outputs[0].try_extract_tensor::<f32>() {
                        t0.1[0]
                    } else if let Ok(t0) = outputs[0].try_extract_tensor::<i64>() {
                        t0.1[0] as f32
                    } else {
                        0.0
                    }
                }
            } else {
                // output 1 not f32
                if let Ok(t0) = outputs[0].try_extract_tensor::<f32>() {
                    t0.1[0]
                } else if let Ok(t0) = outputs[0].try_extract_tensor::<i64>() {
                    t0.1[0] as f32
                } else {
                    0.0
                }
            }
        } else {
            // Only 1 output
            if let Ok(t0) = outputs[0].try_extract_tensor::<f32>() {
                t0.1[0]
            } else if let Ok(t0) = outputs[0].try_extract_tensor::<i64>() {
                t0.1[0] as f32
            } else {
                tracing::error!("Failed to extract any output");
                0.0
            }
        };
        val
    };

    let probability = logit;

    // Update UI with confidence score
    let _ = ui_sender.send(UiMessage::ConfidenceUpdate(tx_hash.clone(), probability));

    // Threshold check (Hardcoded 0.8 or from Config if available)
    if probability < confidence_threshold {
        info!("Tx {} is SAFE (Confidence: {:.4})", tx_hash, probability);
        return Ok(());
    }

    let predator_addr = &tx.from;
    tracing::warn!(
        ">>> PREDATOR DETECTED: {} (Confidence: {:.4} > Threshold {:.4}) <<<",
        predator_addr,
        probability,
        confidence_threshold
    );

    // 0. PRE-CHECK ON-CHAIN STATUS
    let predator_address = Address::from_str(predator_addr).unwrap_or_default();
    match client.is_predator(predator_address).await {
        Ok(true) => {
            info!(
                "Predator {} is ALREADY marked on-chain. Skipping proof generation.",
                predator_addr
            );
            let _ = ui_sender.send(UiMessage::Log(format!(
                "Skipping: {} is already trapped.",
                predator_addr
            )));
            return Ok(());
        }
        Err(e) => {
            tracing::warn!(
                "Failed to check on-chain status for {}: {}",
                predator_addr,
                e
            );
            // Continue on error? Or abort? Let's continue to be safe, or maybe safer to retry?
            // For now, continue but log error.
        }
        _ => {}
    }

    info!("Proceeding to generate ZK Proof and on-chain trap...");

    // Update Stats: Detection & Economic Impact
    {
        let mut stats_guard = stats.lock().await;
        stats_guard.total_detected += 1;
        stats_guard.total_trapped += 1; // Assuming we block it

        let eth_value = (tx.value as f64) / 1e18;
        let saved_eth = eth_value * 0.01; // 1% Slippage Margin saved
        stats_guard.eth_saved += saved_eth;

        // Gas Saved in Gwei
        // total_fee_wei = gas_limit * gas_price
        let gas_price = tx.gas_price.unwrap_or(0);
        let total_fee_gwei = (tx.gas_limit as u128 * gas_price) / 1_000_000_000;
        stats_guard.gas_saved += total_fee_gwei;

        // Efficiency Boost: blocked / scanned * 100
        if stats_guard.total_scanned > 0 {
            stats_guard.efficiency_boost =
                (stats_guard.total_trapped as f32 / stats_guard.total_scanned as f32) * 100.0;
        }

        // History for Sparkline (store as u64 scaled by 1000 for simpler graph or just raw value if supported)
        // Sparkline takes &[u64]. Let's store Accumulated ETH saved * 1000?
        let history_val = (stats_guard.eth_saved * 1000.0) as u64;
        stats_guard.history_saved.push(history_val);
        if stats_guard.history_saved.len() > 100 {
            stats_guard.history_saved.remove(0);
        }

        let stats_copy = (*stats_guard).clone();
        let _ = ui_sender.send(UiMessage::StatsUpdate(stats_copy));
    }

    // 3. GENERATE WITNESS (EZKL)
    let _ = ui_sender.send(UiMessage::ProcessingUpdate(
        ProcessingStage::GeneratingWitness(tx_hash.clone()),
    ));

    // 4. GENERATE ZK PROOF
    let _ = ui_sender.send(UiMessage::ProcessingUpdate(
        ProcessingStage::CreatingZKProof(tx_hash.clone()),
    ));

    // Call EZKL CLI
    let tx_hash_cli = tx_hash.clone();
    let proof_result =
        tokio::task::spawn_blocking(move || run_ezkl_pipeline(&tx_hash_cli)).await??;
    info!("ZK Proof generated for {} : {}", proof_result, tx_hash);
    if proof_result {
        // Update Stats: ZK Proofs
        {
            let mut stats_guard = stats.lock().await;
            stats_guard.zk_proofs_generated += 1;
            let stats_copy = (*stats_guard).clone();
            let _ = ui_sender.send(UiMessage::StatsUpdate(stats_copy));
        }

        let _ = ui_sender.send(UiMessage::ProcessingUpdate(ProcessingStage::ProofComplete(
            tx_hash.clone(),
        )));
        info!("ZK Proof generated for {}", tx_hash);

        // Submit to Chain
        let prove_dir = "assets/prove";
        let calldata_path = format!("{}/calldata_{}.bytes", prove_dir, tx_hash);
        let witness_path = format!("{}/witness_{}.json", prove_dir, tx_hash);

        // Read proof and witness
        match (
            extract_proof_from_calldata(&calldata_path),
            extract_public_output(&witness_path),
        ) {
            (Ok(proof_bytes), Ok(public_inputs)) => {
                let bot_address = Address::from_str(&tx.from).unwrap_or_default();
                match client
                    .submit_detection(bot_address, proof_bytes, public_inputs)
                    .await
                {
                    Ok(tx_hash_chain) => {
                        info!("On-chain submission success: {}", tx_hash_chain);
                        let _ =
                            ui_sender.send(UiMessage::Log(format!("Trapped: {}", tx_hash_chain)));

                        // 5. POST-VERIFICATION
                        // Wait a moment for indexing if needed (Anvil is instant usually)
                        // Verify state
                        match client.is_predator(bot_address).await {
                            Ok(true) => {
                                let msg = format!("SUCCESS: Address {} is officially marked as Predator in contract.", bot_address);
                                info!("{}", msg);
                                let _ = ui_sender.send(UiMessage::Log(msg));
                            }
                            Ok(false) => {
                                let msg = format!("WARNING: Tx succeeded but {} is NOT marked as Predator yet (Pending indexing?).", bot_address);
                                tracing::warn!("{}", msg);
                                let _ = ui_sender.send(UiMessage::Log(msg));
                            }
                            Err(e) => {
                                tracing::error!("Failed to verify on-chain status: {}", e);
                            }
                        }
                    }
                    Err(e) => {
                        error!("On-chain submission failed: {}", e);
                        let _ = ui_sender.send(UiMessage::Log(format!("Trap Failed: {}", e)));
                    }
                }
            }
            (Err(e), _) => error!("Failed to read proof: {}", e),
            (_, Err(e)) => error!("Failed to extract public inputs: {}", e),
        }
    } else {
        let _ = ui_sender.send(UiMessage::ProcessingUpdate(ProcessingStage::Error(
            tx_hash.clone(),
            "EZKL failed".to_string(),
        )));
    }

    Ok(())
}

fn normalize_features(features: &FeatureVector) -> [f32; 6] {
    let arr = features.to_array();
    let mut normalized = [0.0; 6];

    for i in 0..6 {
        if SCALES[i] != 0.0 {
            normalized[i] = (arr[i] - MEANS[i]) / SCALES[i];
        } else {
            normalized[i] = arr[i];
        }
    }

    normalized
}

/// Runs the EZKL CLI pipeline
fn run_ezkl_pipeline(tx_hash: &str) -> Result<bool> {
    // Ensure assets/prove exists
    let prove_dir = "assets/prove";
    std::fs::create_dir_all(prove_dir).wrap_err("Failed to create assets/prove directory")?;

    // Note: In a real app, you would generate a unique input.json per tx
    // For now we use the static one for demo/testing
    let input_file = "assets/input.json";
    let witness_file = format!("{}/witness_{}.json", prove_dir, tx_hash);
    let proof_file = format!("{}/vanguard_{}.proof", prove_dir, tx_hash);

    // 1. Generate Witness
    let witness_output = Command::new("ezkl")
        .args([
            "gen-witness",
            "-D",
            input_file,
            "-M",
            "assets/network.ezkl",
            "-O",
            &witness_file,
        ])
        .output()
        .wrap_err("Failed to execute ezkl gen-witness")?;

    if !witness_output.status.success() {
        error!(
            "Witness generation failed: {}",
            String::from_utf8_lossy(&witness_output.stderr)
        );
        return Ok(false);
    }

    // 2. Generate Proof
    let prove_output = Command::new("ezkl")
        .args([
            "prove",
            "-W",
            &witness_file,
            "-M",
            "assets/network.ezkl",
            "--pk-path",
            "assets/pk.key",
            "--proof-path",
            &proof_file,
            "--srs-path",
            "assets/kzg.srs",
        ])
        .output()
        .wrap_err("Failed to execute ezkl prove")?;

    if !prove_output.status.success() {
        error!(
            "Proof generation failed: {}",
            String::from_utf8_lossy(&prove_output.stderr)
        );
        return Ok(false);
    }

    // 3. Encode Proof to EVM Calldata
    let calldata_file = format!("{}/calldata_{}.bytes", prove_dir, tx_hash);
    let encode_output = Command::new("ezkl")
        .args([
            "encode-evm-calldata",
            "--proof-path",
            &proof_file,
            "--calldata-path",
            &calldata_file,
        ])
        .output()
        .wrap_err("Failed to execute ezkl encode-evm-calldata")?;

    if !encode_output.status.success() {
        error!(
            "Proof encoding failed: {}",
            String::from_utf8_lossy(&encode_output.stderr)
        );
        return Ok(false);
    }

    // let _ = std::fs::remove_file(&proof_file); // Keep proof for now

    Ok(true)
}

fn extract_proof_from_calldata(calldata_path: &str) -> Result<Vec<u8>> {
    let data = std::fs::read(calldata_path)?;

    // EVM encoding:
    // 0x00: Selector (4 bytes)
    // 0x04: Offset to proof (32 bytes)
    // ...

    if data.len() < 100 {
        return Err(eyre::eyre!("Calldata too short"));
    }

    // Read offset to proof (first arg)
    // 4 bytes selector + 32 bytes offset. We want the last 4 bytes of the offset word to get the value as u32.
    // data[4..36] is the 32-byte offset. data[32..36] are the significant bytes (Big Endian)
    let proof_offset_bytes: [u8; 4] = data[32..36].try_into()?;
    let proof_offset = u32::from_be_bytes(proof_offset_bytes) as usize;

    // The length of the proof bytes is at 4 + proof_offset
    let len_offset = 4 + proof_offset;
    if len_offset + 32 > data.len() {
        return Err(eyre::eyre!("Invalid proof offset in calldata"));
    }

    // Read length (32 bytes, Big Endian)
    let len_bytes: [u8; 4] = data[len_offset + 28..len_offset + 32].try_into()?;
    let proof_len = u32::from_be_bytes(len_bytes) as usize;

    let proof_start = len_offset + 32;
    if proof_start + proof_len > data.len() {
        return Err(eyre::eyre!("Invalid proof length in calldata"));
    }

    Ok(data[proof_start..proof_start + proof_len].to_vec())
}

fn extract_public_output(witness_path: &str) -> Result<Vec<U256>> {
    let content = std::fs::read_to_string(witness_path)?;
    let json: serde_json::Value = serde_json::from_str(&content)?;
    let mut public_inputs = Vec::new();

    // Helper to parse value
    let parse_val = |val: &serde_json::Value| -> Result<U256> {
        if let Some(s) = val.as_str() {
            // Check if hex
            if s.starts_with("0x") {
                U256::from_str(s).wrap_err("Failed to parse hex string")
            } else {
                // Try decimal parsing first if it looks like decimal?
                // Or try raw hex parsing (from_str_radix)
                // EZKL raw outputs might be hex without 0x.
                U256::from_str_radix(s, 16)
                    .or_else(|_| U256::from_str(s))
                    .wrap_err("Failed to parse value string")
            }
        } else if let Some(n) = val.as_u64() {
            Ok(U256::from(n))
        } else {
            Err(eyre::eyre!("Invalid value type"))
        }
    };

    // Helper to extract from array of arrays
    let mut extract_from = |key: &str, source: &serde_json::Value| -> Result<()> {
        if let Some(field) = source.get(key) {
            if let Some(arr) = field.as_array() {
                for inner in arr {
                    if let Some(inner_arr) = inner.as_array() {
                        for val in inner_arr {
                            public_inputs.push(parse_val(val)?);
                        }
                    } else {
                        // Handle flat array case if structure differs (some versions)
                        public_inputs.push(parse_val(inner)?);
                    }
                }
            }
        }
        Ok(())
    };

    // Prefer pretty_elements which has 0x prefixed hex strings
    if let Some(pretty) = json.get("pretty_elements") {
        extract_from("inputs", pretty)?;
        extract_from("outputs", pretty)?;
    } else {
        // Fallback to root
        extract_from("inputs", &json)?;
        extract_from("outputs", &json)?;
    }

    if public_inputs.is_empty() {
        return Err(eyre::eyre!("No public inputs found in witness.json"));
    }

    Ok(public_inputs)
}
