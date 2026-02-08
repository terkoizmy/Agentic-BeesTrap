// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ============ Foundry Test Imports ============
import "forge-std/Test.sol";

// ============ Uniswap V4 Test Utilities ============
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

// ============ Contract Under Test ============
import {BeeTrapHook, AggregatorV3Interface, IVerifier} from "../src/BeeTrapHook.sol";
import {Halo2Verifier as Verifier} from "../src/Verifier.sol";

// ============ Mock Oracle ============
/**
 * @title MockOracle
 * @notice A mock implementation of Chainlink's AggregatorV3Interface for testing
 * @dev Allows manual price setting via setPrice() and setUpdatedAt() functions
 */
contract MockOracle is AggregatorV3Interface {
    int256 private _price;
    uint256 private _updatedAt;
    uint8 private constant DECIMALS = 8;

    constructor(int256 initialPrice) {
        _price = initialPrice;
        _updatedAt = block.timestamp;
    }

    /// @notice Set the mock oracle price
    /// @param newPrice The new price to return (8 decimals for ETH/USD)
    function setPrice(int256 newPrice) external {
        _price = newPrice;
    }

    /// @notice Set the last updated timestamp
    /// @param newUpdatedAt The timestamp of the last update
    function setUpdatedAt(uint256 newUpdatedAt) external {
        _updatedAt = newUpdatedAt;
    }

    /// @inheritdoc AggregatorV3Interface
    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (
            1, // roundId
            _price, // answer (price)
            _updatedAt, // startedAt
            _updatedAt, // updatedAt
            1 // answeredInRound
        );
    }

    /// @inheritdoc AggregatorV3Interface
    function decimals() external pure override returns (uint8) {
        return DECIMALS;
    }
}

// ============ Hook Address Miner ============
/**
 * @title HookMiner
 * @notice Helper to find a salt that produces a hook address with correct flag bits
 * @dev For BEFORE_SWAP_FLAG (1 << 7 = 0x80), the address must have bit 7 set.
 */
library HookMiner {
    /// @notice Find a salt that will produce a hook address with the required flags
    /// @param deployer The address that will deploy the hook
    /// @param flags The required hook flags (must be encoded in the address)
    /// @param creationCode The creation code of the hook contract
    /// @param constructorArgs The encoded constructor arguments
    /// @return hookAddress The computed hook address
    /// @return salt The salt to use for CREATE2 deployment
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address hookAddress, bytes32 salt) {
        bytes memory creationCodeWithArgs = abi.encodePacked(
            creationCode,
            constructorArgs
        );
        bytes32 initCodeHash = keccak256(creationCodeWithArgs);

        for (uint256 i = 0; i < 100000; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);

            // Check if the address has ALL required flags set
            // The condition (address & flags == flags) ensures all flag bits are present
            if (uint160(hookAddress) & flags == flags) {
                return (hookAddress, salt);
            }
        }
        revert("HookMiner: could not find salt");
    }

    function computeAddress(
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) internal pure returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                deployer,
                                salt,
                                initCodeHash
                            )
                        )
                    )
                )
            );
    }
}

// ============ Main Test Contract ============
/**
 * @title BeeTrapHookTest
 * @notice Comprehensive unit tests for the BeeTrapHook contract
 * @dev Tests access control, fee overriding, AI detection, and oracle deviation protection
 */
contract BeeTrapHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ============ Test Constants ============

    /// @notice AI Agent address (simulating the off-chain Rust sentinel)
    address constant AI_AGENT = address(0x1337);

    /// @notice Regular user address for normal swap tests
    address constant REGULAR_USER = address(0xBEEF);

    /// @notice Predator bot address for trap tests
    address constant PREDATOR_BOT = address(0xDEAD);

    /// @notice Initial oracle price ($3000 ETH with 8 decimals)
    int256 constant INITIAL_ORACLE_PRICE = 3000e8;

    // ============ Test State Variables ============

    MockOracle oracle;
    PoolKey poolKey;
    PoolId poolId;

    // Hook is pre-defined at an address with ONLY the BEFORE_SWAP_FLAG bit set
    // This follows the v4-core testing pattern from DynamicFees.t.sol
    BeeTrapHook hook =
        BeeTrapHook(
            address(
                uint160(
                    (uint256(type(uint160).max) & clearAllHookPermissionsMask) |
                        Hooks.BEFORE_SWAP_FLAG
                )
            )
        );

    // ============ Events (for testing emissions) ============

    event PredatorStatusChanged(address indexed bot, bool status);
    event PredatorTrapped(
        address indexed predator,
        uint24 feeApplied,
        string reason
    );

    // ============ Setup ============

    /**
     * @notice Set up the test environment before each test
     * @dev Uses vm.etch pattern to deploy hook at a predetermined address with correct flag bits
     */
    function setUp() public {
        // Step 1: Deploy Mock Oracle first (it's a dependency)
        oracle = new MockOracle(INITIAL_ORACLE_PRICE);

        // Step 2: Deploy Uniswap v4 infrastructure (PoolManager, routers)
        deployFreshManagerAndRouters();

        // Step 3: Deploy the hook implementation with correct manager/oracle
        BeeTrapHook hookImpl = new BeeTrapHook(
            manager,
            AI_AGENT,
            AggregatorV3Interface(address(oracle)),
            IVerifier(address(0))
        );

        // Step 4: Etch the implementation bytecode to the predetermined hook address
        // This makes the hook available at an address with correct flag bits
        vm.etch(address(hook), address(hookImpl).code);

        // Step 5: Deploy test tokens (WETH and USDC simulation)
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Step 6: Initialize the pool with the hook and dynamic fees
        (poolKey, poolId) = initPool(
            currency0,
            currency1,
            IHooks(address(hook)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG, // Dynamic fee flag for fee overriding
            SQRT_PRICE_1_1 // 1:1 price ratio
        );

        // Step 7: Add liquidity to the pool for swap testing
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    // ============ Access Control Tests ============

    /**
     * @notice Test that AI Agent can successfully mark an address as predator
     */
    function test_MarkAsPredator_Success() public {
        // Arrange: Verify initial state - bot is not a predator
        assertFalse(
            hook.isPredator(PREDATOR_BOT),
            "Bot should not be predator initially"
        );

        // Act: AI Agent marks the bot as a predator
        vm.prank(AI_AGENT);
        vm.expectEmit(true, false, false, true);
        emit PredatorStatusChanged(PREDATOR_BOT, true);
        hook.markAsPredator(PREDATOR_BOT, true);

        // Assert: Verify the bot is now marked as predator
        assertTrue(
            hook.isPredator(PREDATOR_BOT),
            "Bot should be marked as predator"
        );
    }

    /**
     * @notice Test that AI Agent can unmark an address as predator
     */
    function test_UnmarkAsPredator_Success() public {
        // Arrange: Mark bot as predator first
        vm.prank(AI_AGENT);
        hook.markAsPredator(PREDATOR_BOT, true);
        assertTrue(hook.isPredator(PREDATOR_BOT), "Bot should be predator");

        // Act: AI Agent unmarks the bot
        vm.prank(AI_AGENT);
        vm.expectEmit(true, false, false, true);
        emit PredatorStatusChanged(PREDATOR_BOT, false);
        hook.markAsPredator(PREDATOR_BOT, false);

        // Assert: Bot is no longer a predator
        assertFalse(
            hook.isPredator(PREDATOR_BOT),
            "Bot should no longer be predator"
        );
    }

    /**
     * @notice Test that non-AI addresses cannot mark predators
     */
    function test_MarkAsPredator_RevertIfNotAIAgent() public {
        // Arrange: Use a random unauthorized address
        address unauthorized = address(0x9999);

        // Act & Assert: Expect revert with OnlyAIAgent error
        vm.prank(unauthorized);
        vm.expectRevert(BeeTrapHook.OnlyAIAgent.selector);
        hook.markAsPredator(PREDATOR_BOT, true);
    }

    /**
     * @notice Test that regular user cannot mark predators
     */
    function test_MarkAsPredator_RevertIfRegularUser() public {
        // Act & Assert: Regular user cannot mark predators
        vm.prank(REGULAR_USER);
        vm.expectRevert(BeeTrapHook.OnlyAIAgent.selector);
        hook.markAsPredator(PREDATOR_BOT, true);
    }

    // ============ Normal Swap Fee Tests ============

    /**
     * @notice Test that a regular user gets NORMAL_FEE (0.3%)
     * @dev Simulates a swap from an address not marked as predator
     */
    function test_NormalSwap_ReturnsNormalFee() public {
        // Arrange: Set oracle price to 0 (invalid) to bypass price deviation check
        // When answer <= 0, _checkPriceDeviation returns false early
        oracle.setPrice(0);

        // Create swap params
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15, // Exact input swap
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Act: Call beforeSwap directly to check returned fee
        // Note: In production, this is called by PoolManager, but we test the return values
        vm.prank(address(manager));
        (bytes4 selector, , uint24 fee) = hook.beforeSwap(
            REGULAR_USER,
            poolKey,
            params,
            ZERO_BYTES
        );

        // Assert: Should return normal fee with override flag
        assertEq(
            selector,
            IHooks.beforeSwap.selector,
            "Should return correct selector"
        );
        assertEq(
            fee,
            hook.NORMAL_FEE() | LPFeeLibrary.OVERRIDE_FEE_FLAG,
            "Should return NORMAL_FEE with OVERRIDE_FEE_FLAG"
        );
    }

    // ============ AI Trap Execution Tests ============

    /**
     * @notice Test that a predator-marked address gets TRAP_FEE (10%)
     * @dev Verifies AI detection triggers trap fee and emits correct event
     */
    function test_AITrap_ReturnsTrapFeeForPredator() public {
        // Arrange: Mark address as predator via AI Agent
        vm.prank(AI_AGENT);
        hook.markAsPredator(PREDATOR_BOT, true);

        // Ensure oracle is fresh (no price deviation trigger)
        oracle.setUpdatedAt(block.timestamp);
        oracle.setPrice(INITIAL_ORACLE_PRICE);

        // Create swap params
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Act: Expect PredatorTrapped event with "AI_DETECTED" reason
        vm.expectEmit(true, false, false, true);
        emit PredatorTrapped(PREDATOR_BOT, hook.TRAP_FEE(), "AI_DETECTED");

        vm.prank(address(manager));
        (bytes4 selector, , uint24 fee) = hook.beforeSwap(
            PREDATOR_BOT,
            poolKey,
            params,
            ZERO_BYTES
        );

        // Assert: Should return trap fee with override flag
        assertEq(
            selector,
            IHooks.beforeSwap.selector,
            "Should return correct selector"
        );
        assertEq(
            fee,
            hook.TRAP_FEE() | LPFeeLibrary.OVERRIDE_FEE_FLAG,
            "Should return TRAP_FEE with OVERRIDE_FEE_FLAG"
        );
    }

    /**
     * @notice Test that unmarking predator allows normal fees again
     */
    function test_AITrap_NormalFeeAfterUnmark() public {
        // Arrange: Mark and then unmark as predator
        vm.startPrank(AI_AGENT);
        hook.markAsPredator(PREDATOR_BOT, true);
        hook.markAsPredator(PREDATOR_BOT, false);
        vm.stopPrank();

        // Set oracle price to 0 (invalid) to bypass price deviation check
        oracle.setPrice(0);

        // Create swap params
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Act: Call beforeSwap
        vm.prank(address(manager));
        (, , uint24 fee) = hook.beforeSwap(
            PREDATOR_BOT,
            poolKey,
            params,
            ZERO_BYTES
        );

        // Assert: Should return normal fee (predator was unmarked)
        assertEq(
            fee,
            hook.NORMAL_FEE() | LPFeeLibrary.OVERRIDE_FEE_FLAG,
            "Should return NORMAL_FEE after being unmarked"
        );
    }

    // ============ Oracle Deviation Trap Tests ============

    /**
     * @notice Test that price deviation triggers TRAP_FEE even for non-predator
     * @dev Sets oracle price significantly different from pool price (>2% deviation)
     */
    function test_OracleDeviation_ReturnsTrapFee() public {
        // Arrange: User is NOT marked as predator
        assertFalse(
            hook.isPredator(REGULAR_USER),
            "User should not be a predator"
        );

        // Set oracle to a price that will cause significant deviation
        // The pool is initialized at 1:1 ratio (sqrtPriceX96 = SQRT_PRICE_1_1)
        // Setting oracle price very low will create deviation
        // Pool price is approximately 1, so oracle at 100 will cause huge deviation
        oracle.setUpdatedAt(block.timestamp);
        oracle.setPrice(100e8); // $100 - significantly different from pool price

        // Create swap params
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Act: Expect PredatorTrapped event with "PRICE_DEVIATION" reason
        vm.expectEmit(true, false, false, true);
        emit PredatorTrapped(REGULAR_USER, hook.TRAP_FEE(), "PRICE_DEVIATION");

        vm.prank(address(manager));
        (bytes4 selector, , uint24 fee) = hook.beforeSwap(
            REGULAR_USER,
            poolKey,
            params,
            ZERO_BYTES
        );

        // Assert: Should return trap fee due to price deviation
        assertEq(
            selector,
            IHooks.beforeSwap.selector,
            "Should return correct selector"
        );
        assertEq(
            fee,
            hook.TRAP_FEE() | LPFeeLibrary.OVERRIDE_FEE_FLAG,
            "Should return TRAP_FEE due to price deviation"
        );
    }

    /**
     * @notice Test that stale oracle data does not trigger trap
     * @dev Sets oracle updatedAt to more than 1 hour ago
     */
    function test_OracleStale_ReturnsNormalFee() public {
        // Arrange: Warp to reasonable timestamp, then set oracle data to be stale (>1 hour old)
        vm.warp(10000); // Set to 10000 seconds
        oracle.setUpdatedAt(block.timestamp - 2 hours); // 2 hours ago
        oracle.setPrice(100e8); // Would cause deviation if data wasn't stale

        // User is not a predator
        assertFalse(
            hook.isPredator(REGULAR_USER),
            "User should not be a predator"
        );

        // Create swap params
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Act: Call beforeSwap
        vm.prank(address(manager));
        (, , uint24 fee) = hook.beforeSwap(
            REGULAR_USER,
            poolKey,
            params,
            ZERO_BYTES
        );

        // Assert: Should return normal fee (oracle is stale, conservative approach)
        assertEq(
            fee,
            hook.NORMAL_FEE() | LPFeeLibrary.OVERRIDE_FEE_FLAG,
            "Should return NORMAL_FEE when oracle is stale"
        );
    }

    /**
     * @notice Test that invalid oracle price (<=0) does not trigger trap
     */
    function test_OracleInvalidPrice_ReturnsNormalFee() public {
        // Arrange: Set oracle price to invalid (zero)
        oracle.setUpdatedAt(block.timestamp);
        oracle.setPrice(0);

        // Create swap params
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Act: Call beforeSwap
        vm.prank(address(manager));
        (, , uint24 fee) = hook.beforeSwap(
            REGULAR_USER,
            poolKey,
            params,
            ZERO_BYTES
        );

        // Assert: Should return normal fee (oracle price invalid)
        assertEq(
            fee,
            hook.NORMAL_FEE() | LPFeeLibrary.OVERRIDE_FEE_FLAG,
            "Should return NORMAL_FEE when oracle price is invalid"
        );
    }

    /**
     * @notice Test that negative oracle price does not trigger trap
     */
    function test_OracleNegativePrice_ReturnsNormalFee() public {
        // Arrange: Set oracle price to negative
        oracle.setUpdatedAt(block.timestamp);
        oracle.setPrice(-1000e8);

        // Create swap params
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Act: Call beforeSwap
        vm.prank(address(manager));
        (, , uint24 fee) = hook.beforeSwap(
            REGULAR_USER,
            poolKey,
            params,
            ZERO_BYTES
        );

        // Assert: Should return normal fee (negative price is invalid)
        assertEq(
            fee,
            hook.NORMAL_FEE() | LPFeeLibrary.OVERRIDE_FEE_FLAG,
            "Should return NORMAL_FEE when oracle price is negative"
        );
    }

    // ============ Combined Detection Tests ============

    /**
     * @notice Test that AI detection takes priority over oracle deviation
     * @dev Both conditions are true, but AI detection should emit first
     */
    function test_AIDetection_TakesPriorityOverOracleDeviation() public {
        // Arrange: Mark as predator AND cause price deviation
        vm.prank(AI_AGENT);
        hook.markAsPredator(PREDATOR_BOT, true);

        oracle.setUpdatedAt(block.timestamp);
        oracle.setPrice(100e8); // Would cause deviation

        // Create swap params
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Act: Expect AI_DETECTED event (takes priority)
        vm.expectEmit(true, false, false, true);
        emit PredatorTrapped(PREDATOR_BOT, hook.TRAP_FEE(), "AI_DETECTED");

        vm.prank(address(manager));
        hook.beforeSwap(PREDATOR_BOT, poolKey, params, ZERO_BYTES);
    }

    // ============ View Function Tests ============

    /**
     * @notice Test getOraclePrice returns correct values
     */
    function test_GetOraclePrice() public view {
        // Act: Get oracle price
        (int256 price, uint8 decimals) = hook.getOraclePrice();

        // Assert: Should match mock oracle values
        assertEq(
            price,
            INITIAL_ORACLE_PRICE,
            "Price should match initial oracle price"
        );
        assertEq(decimals, 8, "Decimals should be 8");
    }

    /**
     * @notice Test checkPriceDeviation public view function
     */
    function test_CheckPriceDeviation_View() public {
        // Arrange: Set a price that causes deviation
        oracle.setUpdatedAt(block.timestamp);
        oracle.setPrice(100e8);

        // Act & Assert: Should return true for deviation
        bool isDeviating = hook.checkPriceDeviation(poolKey);
        assertTrue(isDeviating, "Should detect price deviation");
    }

    // ============ Constants Tests ============

    /**
     * @notice Verify hook constants are set correctly
     */
    function test_Constants() public view {
        assertEq(hook.TRAP_FEE(), 100_000, "TRAP_FEE should be 100,000 (10%)");
        assertEq(hook.NORMAL_FEE(), 3_000, "NORMAL_FEE should be 3,000 (0.3%)");
        assertEq(
            hook.DEVIATION_THRESHOLD_BPS(),
            200,
            "DEVIATION_THRESHOLD_BPS should be 200 (2%)"
        );
    }

    /**
     * @notice Verify immutable addresses are set correctly
     */
    function test_ImmutableAddresses() public view {
        assertEq(
            address(hook.POOL_MANAGER()),
            address(manager),
            "POOL_MANAGER should match"
        );
        assertEq(hook.AI_AGENT(), AI_AGENT, "AI_AGENT should match");
        assertEq(
            address(hook.PRICE_FEED()),
            address(oracle),
            "PRICE_FEED should match"
        );
    }

    // ============ Hook Permissions Test ============

    /**
     * @notice Verify that only beforeSwap permission is enabled
     */
    function test_HookPermissions() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();

        // Only beforeSwap should be enabled
        assertTrue(perms.beforeSwap, "beforeSwap should be enabled");

        // All other permissions should be disabled
        assertFalse(
            perms.beforeInitialize,
            "beforeInitialize should be disabled"
        );
        assertFalse(
            perms.afterInitialize,
            "afterInitialize should be disabled"
        );
        assertFalse(
            perms.beforeAddLiquidity,
            "beforeAddLiquidity should be disabled"
        );
        assertFalse(
            perms.afterAddLiquidity,
            "afterAddLiquidity should be disabled"
        );
        assertFalse(
            perms.beforeRemoveLiquidity,
            "beforeRemoveLiquidity should be disabled"
        );
        assertFalse(
            perms.afterRemoveLiquidity,
            "afterRemoveLiquidity should be disabled"
        );
        assertFalse(perms.afterSwap, "afterSwap should be disabled");
        assertFalse(perms.beforeDonate, "beforeDonate should be disabled");
        assertFalse(perms.afterDonate, "afterDonate should be disabled");
    }
}
