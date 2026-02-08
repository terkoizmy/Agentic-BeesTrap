// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// ============ Contract Imports ============
import {AgentNFT} from "../src/AgentNFT.sol";
import {ValidationRegistry} from "../src/ValidationRegistry.sol";
import {BeeTrapHook, AggregatorV3Interface, IVerifier} from "../src/BeeTrapHook.sol";
import {Halo2Verifier as Verifier} from "../src/Verifier.sol";

// ============ Uniswap V4 Imports ============
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/**
 * @title MockOracle
 * @notice Simple Chainlink mock for testing
 */
contract MockOracle is AggregatorV3Interface {
    int256 private _price;
    uint256 private _updatedAt;

    constructor(int256 initialPrice) {
        _price = initialPrice;
        _updatedAt = block.timestamp;
    }

    function setPrice(int256 newPrice) external {
        _price = newPrice;
    }

    function setUpdatedAt(uint256 ts) external {
        _updatedAt = ts;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, _price, _updatedAt, _updatedAt, 1);
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }
}

/**
 * @title BeeTrapIntegrationTest
 * @author BeeTrap Agentic Security Team
 * @notice End-to-end integration test demonstrating the complete BeeTrap workflow
 *
 * @dev This test simulates the full lifecycle of the Agentic BeeTrap system:
 *
 * ┌─────────────────────────────────────────────────────────────────────────────┐
 * │                        BEETRAP WORKFLOW OVERVIEW                            │
 * ├─────────────────────────────────────────────────────────────────────────────┤
 * │                                                                             │
 * │  Phase 1: SETUP                                                             │
 * │  ┌─────────────┐    ┌──────────────────┐    ┌─────────────────┐            │
 * │  │ Deploy      │    │ Deploy           │    │ Deploy          │            │
 * │  │ AgentNFT    │───▶│ ValidationReg    │───▶│ BeeTrapHook     │            │
 * │  └─────────────┘    └──────────────────┘    └─────────────────┘            │
 * │                                                                             │
 * │  Phase 2: AGENT ONBOARDING                                                  │
 * │  ┌─────────────┐    ┌──────────────────┐    ┌─────────────────┐            │
 * │  │ Mint Agent  │    │ Register Agent   │    │ Link to         │            │
 * │  │ NFT (ID=0)  │───▶│ modelHash+exec   │───▶│ BeeTrapHook     │            │
 * │  └─────────────┘    └──────────────────┘    └─────────────────┘            │
 * │                                                                             │
 * │  Phase 3: NORMAL OPERATION                                                  │
 * │  ┌─────────────┐    ┌──────────────────┐                                   │
 * │  │ Regular     │───▶│ BeeTrapHook      │──▶ Returns 0.3% fee              │
 * │  │ User Swap   │    │ beforeSwap()     │                                   │
 * │  └─────────────┘    └──────────────────┘                                   │
 * │                                                                             │
 * │  Phase 4: MEV DETECTION & TRAPPING                                          │
 * │  ┌─────────────┐    ┌──────────────────┐    ┌─────────────────┐            │
 * │  │ AI Sentinel │    │ ValidationReg    │    │ BeeTrapHook     │            │
 * │  │ detects bot │───▶│ verifyDetection  │───▶│ markAsPredator  │            │
 * │  │ + signs     │    │ (ECDSA verify)   │    │                 │            │
 * │  └─────────────┘    └──────────────────┘    └─────────────────┘            │
 * │                             │                        │                      │
 * │                             ▼                        ▼                      │
 * │  ┌─────────────┐    ┌──────────────────┐                                   │
 * │  │ Predator    │───▶│ BeeTrapHook      │──▶ Returns 10% TRAP FEE! 🐝       │
 * │  │ Bot Swap    │    │ beforeSwap()     │                                   │
 * │  └─────────────┘    └──────────────────┘                                   │
 * │                                                                             │
 * └─────────────────────────────────────────────────────────────────────────────┘
 */
contract BeeTrapIntegrationTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ============ Actors ============

    /// @notice Platform owner who deploys and controls the system
    address public platformOwner;

    /// @notice The AI Sentinel's wallet (Rust agent with private key)
    address public aiSentinel;
    uint256 public aiSentinelPrivateKey;

    /// @notice Regular DeFi user making normal swaps
    address public regularUser = address(0xCAFE);

    /// @notice MEV sandwich bot trying to extract value
    address public mevBot = address(0xBAD);

    // ============ Contracts ============

    AgentNFT public agentNFT;
    ValidationRegistry public validationRegistry;
    BeeTrapHook public beeTrapHook;
    MockOracle public priceOracle;

    // ============ Pool State ============

    PoolKey public poolKey;
    PoolId public poolId;

    // ============ Constants ============

    bytes32 public constant MODEL_HASH = keccak256("beetrap_model.onnx");
    string public constant AGENT_URI = "ipfs://QmBeeTrapAgent";
    int256 public constant INITIAL_PRICE = 3000e8; // $3000 ETH

    // ============ Events to Expect ============

    event AgentMinted(uint256 indexed tokenId, address indexed to, string uri);
    event AgentRegistered(
        uint256 indexed nftId,
        bytes32 modelHash,
        address executor,
        ValidationRegistry.ValidationMode mode
    );
    event PredatorStatusChanged(address indexed bot, bool status);
    event PredatorTrapped(
        address indexed predator,
        uint24 feeApplied,
        string reason
    );

    // ═══════════════════════════════════════════════════════════════════════════
    //                              SETUP PHASE
    // ═══════════════════════════════════════════════════════════════════════════

    function setUp() public {
        console.log("========================================");
        console.log("   BEETRAP INTEGRATION TEST - SETUP");
        console.log("========================================");

        // Create actors
        platformOwner = address(this);
        aiSentinelPrivateKey = 0xA1;
        aiSentinel = vm.addr(aiSentinelPrivateKey);

        console.log("Platform Owner:", platformOwner);
        console.log("AI Sentinel:   ", aiSentinel);
        console.log("Regular User:  ", regularUser);
        console.log("MEV Bot:       ", mevBot);
        console.log("");

        // ─────────────────────────────────────────────────────────────────────
        // Step 1: Deploy Core Infrastructure
        // ─────────────────────────────────────────────────────────────────────
        console.log("[1] Deploying Uniswap V4 infrastructure...");
        deployFreshManagerAndRouters();
        console.log("    PoolManager deployed at:", address(manager));

        // ─────────────────────────────────────────────────────────────────────
        // Step 2: Deploy BeeTrap Contracts
        // ─────────────────────────────────────────────────────────────────────
        console.log("[2] Deploying BeeTrap contracts...");

        // Deploy Price Oracle
        priceOracle = new MockOracle(INITIAL_PRICE);
        console.log("    MockOracle deployed at:", address(priceOracle));

        // Deploy AgentNFT
        // Deploy AgentNFT with mock verifier
        address verifier = address(0xDEAD);
        agentNFT = new AgentNFT(platformOwner, verifier);
        console.log("    AgentNFT deployed at:", address(agentNFT));

        // Deploy ValidationRegistry
        validationRegistry = new ValidationRegistry(address(agentNFT));
        console.log(
            "    ValidationRegistry deployed at:",
            address(validationRegistry)
        );

        // Deploy BeeTrapHook (at predetermined address with correct flags)
        // Deploy BeeTrapHook (at predetermined address with correct flags)
        BeeTrapHook hookImpl = new BeeTrapHook(
            manager,
            aiSentinel,
            AggregatorV3Interface(address(priceOracle)),
            IVerifier(address(0xDEAD)) // Mock verifier for integration test
        );

        // Compute hook address with BEFORE_SWAP_FLAG
        address hookAddress = address(
            uint160(
                (uint256(type(uint160).max) & clearAllHookPermissionsMask) |
                    Hooks.BEFORE_SWAP_FLAG
            )
        );
        vm.etch(hookAddress, address(hookImpl).code);
        beeTrapHook = BeeTrapHook(hookAddress);
        console.log("    BeeTrapHook deployed at:", hookAddress);

        // ─────────────────────────────────────────────────────────────────────
        // Step 3: Deploy Test Tokens and Initialize Pool
        // ─────────────────────────────────────────────────────────────────────
        console.log("[3] Deploying tokens and initializing pool...");
        (currency0, currency1) = deployMintAndApprove2Currencies();
        console.log("    Token0:", Currency.unwrap(currency0));
        console.log("    Token1:", Currency.unwrap(currency1));

        (poolKey, poolId) = initPool(
            currency0,
            currency1,
            IHooks(address(beeTrapHook)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );
        console.log("    Pool initialized with BeeTrapHook");

        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        console.log("    Added 100 ETH of liquidity");
        console.log("");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        COMPLETE WORKFLOW TEST
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Tests the complete BeeTrap workflow from start to finish
     * @dev This is the main integration test that demonstrates all phases
     */
    function test_CompleteWorkflow_AgentOnboarding_NormalSwap_MEVTrap() public {
        console.log("========================================");
        console.log("   PHASE 1: AGENT ONBOARDING");
        console.log("========================================");

        // ─────────────────────────────────────────────────────────────────────
        // Step 1.1: Mint Agent NFT
        // ─────────────────────────────────────────────────────────────────────
        console.log("[1.1] Platform owner mints Agent NFT...");

        vm.expectEmit(true, true, false, true);
        emit AgentMinted(0, aiSentinel, AGENT_URI);

        uint256 agentId = agentNFT.mint(aiSentinel, AGENT_URI);

        assertEq(agentNFT.ownerOf(agentId), aiSentinel);
        assertEq(agentNFT.tokenURI(agentId), AGENT_URI);
        console.log("      Agent NFT minted with ID:", agentId);
        console.log("      Owner:", aiSentinel);
        console.log("");

        // ─────────────────────────────────────────────────────────────────────
        // Step 1.2: Register Agent in ValidationRegistry
        // ─────────────────────────────────────────────────────────────────────
        console.log("[1.2] AI Sentinel registers agent configuration...");

        vm.prank(aiSentinel);
        vm.expectEmit(true, false, false, true);
        emit AgentRegistered(
            agentId,
            MODEL_HASH,
            aiSentinel,
            ValidationRegistry.ValidationMode.SIGNATURE
        );

        validationRegistry.registerAgent(agentId, MODEL_HASH, aiSentinel);

        ValidationRegistry.AgentConfig memory config = validationRegistry
            .getAgentConfig(agentId);
        assertEq(config.modelHash, MODEL_HASH);
        assertEq(config.executor, aiSentinel);
        assertTrue(config.isActive);
        console.log("      Model Hash: beetrap_model.onnx");
        console.log("      Executor:  ", aiSentinel);
        console.log("      Mode: SIGNATURE (ECDSA)");
        console.log("");

        console.log("========================================");
        console.log("   PHASE 2: NORMAL OPERATION");
        console.log("========================================");

        // ─────────────────────────────────────────────────────────────────────
        // Step 2.1: Regular User Makes a Normal Swap
        // ─────────────────────────────────────────────────────────────────────
        console.log("[2.1] Regular user attempts a swap...");

        // Set oracle to invalid (0) to bypass price deviation for this test
        priceOracle.setPrice(0);

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.prank(address(manager));
        (bytes4 selector, , uint24 fee) = beeTrapHook.beforeSwap(
            regularUser,
            poolKey,
            swapParams,
            ZERO_BYTES
        );

        uint24 normalFee = beeTrapHook.NORMAL_FEE();
        uint24 expectedFee = normalFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(fee, expectedFee);
        console.log("      User:", regularUser);
        console.log("      Result: NORMAL_FEE (0.3%)");
        console.log("      Fee returned:", normalFee);
        console.log("");

        console.log("========================================");
        console.log("   PHASE 3: MEV DETECTION & TRAPPING");
        console.log("========================================");

        // ─────────────────────────────────────────────────────────────────────
        // Step 3.1: AI Sentinel Detects MEV Bot in Mempool
        // ─────────────────────────────────────────────────────────────────────
        console.log(
            "[3.1] AI Sentinel monitors mempool and detects sandwich attack..."
        );
        console.log("      Detected predator bot:", mevBot);
        console.log("      Running ONNX model inference...");
        console.log("      Prediction: MEV_SANDWICH_BOT (confidence: 98.7%)");
        console.log("");

        // ─────────────────────────────────────────────────────────────────────
        // Step 3.2: AI Sentinel Signs Detection Message
        // ─────────────────────────────────────────────────────────────────────
        console.log("[3.2] AI Sentinel signs detection with ECDSA...");

        uint256 detectionTimestamp = block.timestamp;
        bytes memory signature = _signDetection(
            mevBot,
            detectionTimestamp,
            MODEL_HASH,
            aiSentinelPrivateKey
        );

        console.log("      Target:", mevBot);
        console.log("      Timestamp:", detectionTimestamp);
        console.log("      Signature created (65 bytes)");
        console.log("");

        // ─────────────────────────────────────────────────────────────────────
        // Step 3.3: Verify Detection via ValidationRegistry
        // ─────────────────────────────────────────────────────────────────────
        console.log("[3.3] Verifying detection via ValidationRegistry...");

        bool isValid = validationRegistry.verifyDetection(
            agentId,
            mevBot,
            detectionTimestamp,
            signature
        );

        assertTrue(isValid, "Detection should be valid");
        console.log("      ECDSA.recover verified signature");
        console.log("      Signer matches registered executor: TRUE");
        console.log("      Detection VERIFIED!");
        console.log("");

        // ─────────────────────────────────────────────────────────────────────
        // Step 3.4: Mark Predator in BeeTrapHook
        // ─────────────────────────────────────────────────────────────────────
        console.log("[3.4] AI Sentinel marks predator in BeeTrapHook...");

        vm.prank(aiSentinel);
        vm.expectEmit(true, false, false, true);
        emit PredatorStatusChanged(mevBot, true);

        beeTrapHook.markAsPredator(mevBot, true);

        assertTrue(beeTrapHook.isPredator(mevBot));
        console.log("      isPredator[", mevBot, "] = true");
        console.log("");

        console.log("========================================");
        console.log("   PHASE 4: TRAP EXECUTION");
        console.log("========================================");

        // ─────────────────────────────────────────────────────────────────────
        // Step 4.1: MEV Bot Attempts Swap - GETS TRAPPED!
        // ─────────────────────────────────────────────────────────────────────
        console.log("[4.1] MEV bot attempts sandwich attack swap...");

        vm.prank(address(manager));
        vm.expectEmit(true, false, false, true);
        emit PredatorTrapped(mevBot, 100000, "AI_DETECTED");

        (bytes4 trapSelector, , uint24 trapFee) = beeTrapHook.beforeSwap(
            mevBot,
            poolKey,
            swapParams,
            ZERO_BYTES
        );

        uint24 expectedTrapFee = beeTrapHook.TRAP_FEE();
        uint24 fullTrapFee = expectedTrapFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        assertEq(trapSelector, IHooks.beforeSwap.selector);
        assertEq(trapFee, fullTrapFee);

        console.log("      Bot:", mevBot);
        console.log("      Result: TRAP_FEE (10%) APPLIED!");
        console.log("      Fee returned:", expectedTrapFee);
        console.log("");
        console.log("  ============================================");
        console.log("  |  SANDWICH BOT TRAPPED! 10% FEE APPLIED!  |");
        console.log("  |  LP profits from failed MEV attack       |");
        console.log("  ============================================");
        console.log("");

        console.log("========================================");
        console.log("   WORKFLOW COMPLETE - ALL TESTS PASSED");
        console.log("========================================");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        ADDITIONAL SCENARIO TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Test the upgrade path from SIGNATURE to EZKL mode
     */
    function test_Workflow_UpgradeToEZKL() public {
        console.log("========================================");
        console.log("   EZKL UPGRADE WORKFLOW");
        console.log("========================================");

        // Mint and register agent
        uint256 agentId = agentNFT.mint(aiSentinel, AGENT_URI);

        vm.startPrank(aiSentinel);
        validationRegistry.registerAgent(agentId, MODEL_HASH, aiSentinel);

        // Verify initial mode
        assertEq(
            uint8(validationRegistry.getValidationMode(agentId)),
            uint8(ValidationRegistry.ValidationMode.SIGNATURE)
        );
        console.log("[1] Agent registered in SIGNATURE mode");

        // Deploy mock ZK verifier
        address mockVerifier = address(0x2222);
        vm.etch(mockVerifier, hex"00");

        // Upgrade to EZKL
        validationRegistry.updateToEZKL(agentId, mockVerifier);

        assertEq(
            uint8(validationRegistry.getValidationMode(agentId)),
            uint8(ValidationRegistry.ValidationMode.EZKL_PROOF)
        );
        console.log("[2] Agent upgraded to EZKL_PROOF mode");
        console.log("    ZK Verifier:", mockVerifier);

        vm.stopPrank();
        console.log("[3] Future detections will use zkML proofs!");
    }

    /**
     * @notice Test oracle-based price deviation detection
     */
    function test_Workflow_OracleDeviationTrap() public {
        console.log("========================================");
        console.log("   ORACLE DEVIATION DETECTION");
        console.log("========================================");

        // Set oracle to fresh valid price
        vm.warp(1000);
        priceOracle.setUpdatedAt(block.timestamp);
        priceOracle.setPrice(100e8); // Significantly different from pool price

        console.log("[1] Oracle price set to $100 (pool price ~$1)");
        console.log("    Deviation > 2% threshold");

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Any user triggers deviation trap
        vm.prank(address(manager));
        (, , uint24 fee) = beeTrapHook.beforeSwap(
            regularUser,
            poolKey,
            swapParams,
            ZERO_BYTES
        );

        uint24 trapFee = beeTrapHook.TRAP_FEE() |
            LPFeeLibrary.OVERRIDE_FEE_FLAG;
        assertEq(fee, trapFee);

        console.log("[2] Swap detected PRICE_DEVIATION");
        console.log("[3] TRAP_FEE (10%) applied!");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function _signDetection(
        address targetBot,
        uint256 timestamp,
        bytes32 modelHash,
        uint256 privateKey
    ) internal pure returns (bytes memory) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(targetBot, timestamp, modelHash)
        );
        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }
}
