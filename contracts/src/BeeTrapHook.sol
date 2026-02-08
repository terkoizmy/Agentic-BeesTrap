// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ============ Uniswap V4 Core Imports ============
import {BaseTestHooks} from "v4-core/test/BaseTestHooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

// ============ Chainlink Oracle Interface ============
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function decimals() external view returns (uint8);
}

// ============ ZK Verifier Interface ============
/// @notice Interface for EZKL-generated Halo2 verifier
interface IVerifier {
    function verifyProof(
        bytes calldata proof,
        uint256[] calldata instances
    ) external returns (bool);
}

/**
 * @title BeeTrapHook
 * @author BeeTrap Agentic Security Team
 * @notice A Uniswap V4 Hook designed to protect Liquidity Providers from MEV Sandwich Bots.
 * @dev This hook implements a multi-layered defense mechanism:
 *      1. Off-chain AI Agent monitoring the mempool and marking predator addresses
 *      2. On-chain Chainlink Oracle for price deviation detection
 *      3. Zero-Knowledge Proofs for verifiable AI decisions (via EZKL)
 *
 * When a predator is detected (either by AI or price manipulation), the hook
 * applies an extreme 10% fee, effectively "trapping" the sandwich bot and
 * converting their attack into profit for LPs.
 */
contract BeeTrapHook is BaseTestHooks {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    // ============ State Variables ============

    /// @notice Reference to the Uniswap V4 Pool Manager
    IPoolManager public immutable POOL_MANAGER;

    /// @notice Address of the off-chain AI Agent authorized to mark predators
    address public immutable AI_AGENT;

    /// @notice Chainlink price feed for anchor price (e.g., ETH/USD)
    AggregatorV3Interface public immutable PRICE_FEED;

    /// @notice ZK Verifier contract for proof verification
    IVerifier public immutable VERIFIER;

    /// @notice Mapping of addresses identified as predator bots by the AI Agent
    mapping(address => bool) public isPredator;

    // ============ Constants ============

    /// @notice The extreme fee applied to trapped predators (10% = 100,000 in hundredths of bips)
    uint24 public constant TRAP_FEE = 100_000;

    /// @notice The normal fee for regular swaps (0.3% = 3,000 in hundredths of bips)
    uint24 public constant NORMAL_FEE = 3_000;

    /// @notice The price deviation threshold in basis points (2% = 200 bps)
    uint256 public constant DEVIATION_THRESHOLD_BPS = 200;

    /// @notice Basis points denominator for percentage calculations
    uint256 private constant BPS_DENOMINATOR = 10_000;

    // ============ Events ============

    /// @notice Emitted when an address is marked or unmarked as a predator
    event PredatorStatusChanged(address indexed bot, bool status);

    /// @notice Emitted when a predator is trapped with extreme fees
    event PredatorTrapped(
        address indexed predator,
        uint24 feeApplied,
        string reason
    );

    /// @notice Emitted when a ZK proof is verified
    event ProofVerified(address indexed bot, bool valid);

    // ============ Errors ============

    /// @notice Thrown when a non-AI agent tries to mark predators
    error OnlyAIAgent();

    /// @notice Thrown when ZK proof verification fails
    error InvalidZKProof();

    // ============ Constructor ============

    /**
     * @notice Initializes the BeeTrap Hook with required dependencies
     * @param _poolManager The Uniswap V4 Pool Manager contract
     * @param _aiAgent The address of the off-chain AI Agent
     * @param _priceFeed The Chainlink price feed contract address
     * @param _verifier The ZK proof verifier contract address
     */
    constructor(
        IPoolManager _poolManager,
        address _aiAgent,
        AggregatorV3Interface _priceFeed,
        IVerifier _verifier
    ) {
        POOL_MANAGER = _poolManager;
        AI_AGENT = _aiAgent;
        PRICE_FEED = _priceFeed;
        VERIFIER = _verifier;
    }

    // ============ Hook Permissions ============

    function getHookPermissions()
        public
        pure
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // ============ AI Agent Functions ============

    /**
     * @notice Marks or unmarks an address as a predator bot (without ZK proof)
     * @dev Can only be called by the designated AI Agent address
     * @param bot The address to mark/unmark
     * @param status True to mark as predator, false to unmark
     */
    function markAsPredator(address bot, bool status) external {
        if (msg.sender != AI_AGENT) {
            revert OnlyAIAgent();
        }

        isPredator[bot] = status;
        emit PredatorStatusChanged(bot, status);
    }

    /**
     * @notice Marks or unmarks an address as a predator bot WITH ZK proof verification
     * @dev Verifies the ZK proof before marking to ensure AI decision is valid
     * @param bot The address to mark/unmark
     * @param status True to mark as predator, false to unmark
     * @param proof The ZK proof bytes from EZKL
     * @param publicInputs The public inputs (normalized features) used in the proof
     */
    function markAsPredatorWithProof(
        address bot,
        bool status,
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external {
        if (msg.sender != AI_AGENT) {
            revert OnlyAIAgent();
        }

        // Verify ZK proof
        bool isValid = VERIFIER.verifyProof(proof, publicInputs);
        emit ProofVerified(bot, isValid);

        if (!isValid) {
            revert InvalidZKProof();
        }

        // Mark predator
        isPredator[bot] = status;
        emit PredatorStatusChanged(bot, status);
    }

    // ============ Hook Implementation ============

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        // Silence unused parameter warnings
        (key, params, hookData);

        // Check condition 1: Is the sender marked as a predator by AI?
        // Note: We check tx.origin to catch the EOA behind a bot contract/router
        address predator = address(0);
        if (isPredator[sender]) {
            predator = sender;
        } else if (isPredator[tx.origin]) {
            predator = tx.origin;
        }

        if (predator != address(0)) {
            emit PredatorTrapped(predator, TRAP_FEE, "AI_DETECTED");
            return (
                IHooks.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                TRAP_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }

        // Check condition 2: Is there significant price deviation?
        if (_checkPriceDeviation(key)) {
            emit PredatorTrapped(sender, TRAP_FEE, "PRICE_DEVIATION");
            return (
                IHooks.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                TRAP_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }

        // No predator detected - apply normal fee
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            NORMAL_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    // ============ Oracle Functions ============

    function _checkPriceDeviation(
        PoolKey calldata key
    ) internal view returns (bool) {
        // 1. Fetch oracle price from Chainlink
        (, int256 answer, , uint256 updatedAt, ) = PRICE_FEED.latestRoundData();
        if (answer <= 0 || block.timestamp - updatedAt > 1 hours) return false;
        uint256 oraclePrice = uint256(answer);

        // 2. Get sqrtPriceX96 from Pool Manager
        (uint160 sqrtPriceX96, , , ) = POOL_MANAGER.getSlot0(key.toId());

        // 3. Convert sqrtPriceX96 to Price
        uint256 poolPrice = FullMath.mulDiv(
            uint256(sqrtPriceX96),
            uint256(sqrtPriceX96),
            1 << 192
        );

        // 4. Calculate deviation
        uint256 diff = poolPrice > oraclePrice
            ? poolPrice - oraclePrice
            : oraclePrice - poolPrice;
        uint256 deviationBps = (diff * BPS_DENOMINATOR) / oraclePrice;

        return deviationBps > DEVIATION_THRESHOLD_BPS;
    }

    function checkPriceDeviation(
        PoolKey calldata key
    ) external view returns (bool isDeviating) {
        return _checkPriceDeviation(key);
    }

    function getOraclePrice()
        external
        view
        returns (int256 price, uint8 decimals)
    {
        (, price, , , ) = PRICE_FEED.latestRoundData();
        decimals = PRICE_FEED.decimals();
    }
}
