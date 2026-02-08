// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {AgentNFT} from "../src/AgentNFT.sol";
import {ValidationRegistry} from "../src/ValidationRegistry.sol";
import {BeeTrapHook, AggregatorV3Interface, IVerifier} from "../src/BeeTrapHook.sol";
import {Halo2Verifier as Verifier} from "../src/Verifier.sol";

/// @notice Mock PoolManager for local testing (avoids size limit issues)
contract MockPoolManager {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }
}

/// @notice Mock price feed for testing
contract MockPriceFeed {
    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, 2000 * 10 ** 8, block.timestamp, block.timestamp, 1);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

/**
 * @title DeployBeeTrap
 * @notice Deployment script for BeeTrap on Anvil (simplified - no real PoolManager)
 * @dev Run: forge script script/DeployBeeTrap.s.sol:DeployBeeTrap --rpc-url http://localhost:8545 --broadcast -vvv
 */
contract DeployBeeTrap is Script {
    uint256 constant ANVIL_PRIVATE_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", ANVIL_PRIVATE_KEY);
        address deployer = vm.addr(deployerPrivateKey);

        console.log("========================================");
        console.log("   BEETRAP DEPLOYMENT (ANVIL)");
        console.log("========================================");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy Mock PoolManager (avoids contract size limit)
        console.log("[1/5] Deploying MockPoolManager...");
        MockPoolManager mockPool = new MockPoolManager(deployer);
        console.log("      MockPoolManager:", address(mockPool));

        // Step 2: Deploy AgentNFT
        console.log("[2/5] Deploying AgentNFT...");
        // Mock verifier for deployment for now (or a real one if we deploy it)
        address verifier = address(0xDEAD); // Placeholder
        AgentNFT agentNFT = new AgentNFT(deployer, verifier);
        console.log("      AgentNFT:", address(agentNFT));

        // Step 3: Deploy ValidationRegistry
        console.log("[3/5] Deploying ValidationRegistry...");
        ValidationRegistry validationRegistry = new ValidationRegistry(
            address(agentNFT)
        );
        console.log("      ValidationRegistry:", address(validationRegistry));

        // Step 4: Deploy MockPriceFeed
        console.log("[4/5] Deploying MockPriceFeed...");
        MockPriceFeed mockPriceFeed = new MockPriceFeed();
        console.log("      MockPriceFeed:", address(mockPriceFeed));

        // Step 5: Deploy BeeTrapHook
        console.log("[5/5] Deploying BeeTrapHook...");
        Verifier verifierContract = new Verifier();
        console.log("      Verifier:", address(verifierContract));
        BeeTrapHook hook = new BeeTrapHook(
            IPoolManager(address(mockPool)),
            deployer, // AI Agent = deployer for testing
            AggregatorV3Interface(address(mockPriceFeed)),
            IVerifier(address(verifierContract))
        );
        console.log("      BeeTrapHook:", address(hook));

        vm.stopBroadcast();

        // Print summary with proper format
        console.log("");
        console.log("========================================");
        console.log("   DEPLOYMENT COMPLETE!");
        console.log("========================================");
        console.log("");
        console.log("Copy these to your .env file:");
        console.log("------------------------------");
        string memory env = string.concat(
            "POOL_MANAGER_ADDRESS=",
            vm.toString(address(mockPool)),
            "\n",
            "AGENT_NFT_ADDRESS=",
            vm.toString(address(agentNFT)),
            "\n",
            "VALIDATION_REGISTRY_ADDRESS=",
            vm.toString(address(validationRegistry)),
            "\n",
            "HOOK_ADDRESS=",
            vm.toString(address(hook))
        );
        console.log(env);
        console.log("");
    }
}

/**
 * @title SetupAgent
 * @notice Mint Agent NFT and register it - pass addresses as args instead of env
 * @dev Run: forge script script/DeployBeeTrap.s.sol:SetupAgent --rpc-url http://localhost:8545 --broadcast -vvv --sig "run(address,address)" <AGENT_NFT_ADDRESS> <VALIDATION_REGISTRY_ADDRESS>
 */
contract SetupAgent is Script {
    uint256 constant ANVIL_PRIVATE_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run(
        address agentNFTAddr,
        address validationRegistryAddr
    ) external {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", ANVIL_PRIVATE_KEY);
        address deployer = vm.addr(deployerPrivateKey);

        AgentNFT agentNFT = AgentNFT(agentNFTAddr);
        ValidationRegistry registry = ValidationRegistry(
            validationRegistryAddr
        );

        console.log("========================================");
        console.log("   AGENT SETUP");
        console.log("========================================");
        console.log("AgentNFT:", agentNFTAddr);
        console.log("Registry:", validationRegistryAddr);

        vm.startBroadcast(deployerPrivateKey);

        // Mint Agent NFT
        console.log("[1/2] Minting Agent NFT...");
        uint256 tokenId = agentNFT.mint(deployer, "ipfs://beetrap-agent");
        console.log("      Minted NFT ID:", tokenId);

        // Register agent
        console.log("[2/2] Registering agent...");
        bytes32 modelHash = keccak256("beetrap_model.onnx");
        registry.registerAgent(tokenId, modelHash, deployer);
        console.log("      Registered with model hash");

        vm.stopBroadcast();

        console.log("");
        console.log("   AGENT SETUP COMPLETE!");
        console.log("Add to .env: AGENT_NFT_ID=", tokenId);
    }
}
