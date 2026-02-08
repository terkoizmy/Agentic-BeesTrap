use crate::types::Config;
use alloy::primitives::{Address, Bytes, U256};
use alloy::providers::{Provider, ProviderBuilder, WsConnect};
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use eyre::{Result, WrapErr};
use std::str::FromStr;

// Define the AgentNFT interface (Proxy)
sol! {
    #[sol(rpc)]
    contract AgentNFT {
        function markAsPredatorWithProof(
            uint256 tokenId,
            address bot,
            bool status,
            bytes calldata proof,
            uint256[] calldata publicInputs
        ) external;
    }

    #[sol(rpc)]
    contract BeeTrapHook {
        function isPredator(address) external view returns (bool);
        function markAsPredatorWithProof(
            address bot,
            bool status,
            bytes calldata proof,
            uint256[] calldata publicInputs
        ) external;
    }
}

/// Client for interacting with the BeeTrap on-chain system
pub struct SentinelClient<P> {
    agent_nft:
        AgentNFT::AgentNFTInstance<alloy::pubsub::PubSubFrontend, P, alloy::network::Ethereum>,
    beetrap_hook: BeeTrapHook::BeeTrapHookInstance<
        alloy::pubsub::PubSubFrontend,
        P,
        alloy::network::Ethereum,
    >,
    agent_token_id: U256,
}

impl<P> SentinelClient<P>
where
    P: Provider<alloy::pubsub::PubSubFrontend, alloy::network::Ethereum> + Clone,
{
    /// Create a new SentinelClient
    pub fn new(provider: P, agent_nft_addr: Address, hook_addr: Address, token_id: U256) -> Self {
        let agent_nft = AgentNFT::new(agent_nft_addr, provider.clone());
        let beetrap_hook = BeeTrapHook::new(hook_addr, provider);
        Self {
            agent_nft,
            beetrap_hook,
            agent_token_id: token_id,
        }
    }

    /// Submit a predator detection with ZK proof
    pub async fn submit_detection(
        &self,
        bot_address: Address,
        proof_bytes: Vec<u8>,
        public_inputs: Vec<U256>,
    ) -> Result<String> {
        let proof = Bytes::from(proof_bytes);

        // Call the BeeTrapHook directly (Bypassing AgentNFT to ensure msg.sender == AI_AGENT)
        let tx = self
            .beetrap_hook
            .markAsPredatorWithProof(
                bot_address,
                true, // status = true
                proof,
                public_inputs,
            )
            .send()
            .await?;

        let receipt = tx.get_receipt().await?;
        let hash = receipt.transaction_hash;

        Ok(hash.to_string())
    }

    /// Check if an address is already marked as a predator
    pub async fn is_predator(&self, bot_address: Address) -> Result<bool> {
        let return_value = self.beetrap_hook.isPredator(bot_address).call().await?;
        Ok(return_value._0)
    }
}

/// Build the client with recommended fillers and wallet
pub async fn build_client(
    config: &Config,
) -> Result<
    SentinelClient<impl Provider<alloy::pubsub::PubSubFrontend, alloy::network::Ethereum> + Clone>,
> {
    let signer = PrivateKeySigner::from_str(&config.private_key).wrap_err("Invalid private key")?;
    let wallet = alloy::network::EthereumWallet::from(signer);

    let ws = WsConnect::new(&config.rpc_url);
    let provider = ProviderBuilder::new()
        .with_recommended_fillers()
        .wallet(wallet)
        .on_ws(ws)
        .await?;

    let agent_nft_address =
        Address::from_str(&config.agent_nft_address).wrap_err("Invalid AgentNFT address")?;
    let hook_address =
        Address::from_str(&config.hook_address).wrap_err("Invalid BeeTrapHook address")?;

    Ok(SentinelClient::new(
        provider,
        agent_nft_address,
        hook_address,
        U256::from(config.agent_nft_id),
    ))
}
