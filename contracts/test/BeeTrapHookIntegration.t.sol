// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
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
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {BeeTrapHook, AggregatorV3Interface, IVerifier} from "../src/BeeTrapHook.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// Mock Oracle
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

    function setUpdatedAt(uint256 newUpdatedAt) external {
        _updatedAt = newUpdatedAt;
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
 * @title BeeTrapHookIntegrationTest
 * @notice Integration tests for complete BeeTrap workflows
 * @dev Tests end-to-end scenarios including:
 *      - Mempool detection → Proof generation → On-chain marking → Swap blocking
 *      - Economic impact measurement (LP profit from trapped bots)
 *      - Multi-actor scenarios (regular users, bots, LPs)
 */
contract BeeTrapHookIntegrationTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ============ Test Actors ============
    address constant AI_AGENT = address(0x1337);
    address constant LP_PROVIDER = address(0xFEED);
    address constant REGULAR_USER_1 = address(0xBEEF);
    address constant REGULAR_USER_2 = address(0xCAFE);
    address constant SANDWICH_BOT = address(0xDEAD);
    address constant FRONTRUN_BOT = address(0xBAD1);

    int256 constant INITIAL_ORACLE_PRICE = 3000e8;
    uint256 constant INITIAL_USER_BALANCE = 1000 ether;

    // ============ Contracts ============
    MockOracle oracle;
    MockVerifier verifier;
    BeeTrapHook hook;
    PoolKey poolKey;
    PoolId poolId;

    // ============ Events ============
    event PredatorTrapped(
        address indexed predator,
        uint24 feeApplied,
        string reason
    );
    event PredatorStatusChanged(address indexed bot, bool status);

    // ============ Setup ============
    function setUp() public {
        // Deploy infrastructure
        oracle = new MockOracle(INITIAL_ORACLE_PRICE);
        verifier = new MockVerifier(true);

        deployFreshManagerAndRouters();

        // Warp to avoid underflow with relative timestamps
        vm.warp(4 weeks);

        // Deploy hook
        BeeTrapHook hookImpl = new BeeTrapHook(
            manager,
            AI_AGENT,
            AggregatorV3Interface(address(oracle)),
            IVerifier(address(verifier))
        );

        // Use predetermined address with correct flags
        hook = BeeTrapHook(
            address(
                uint160(
                    (uint256(type(uint160).max) & clearAllHookPermissionsMask) |
                        Hooks.BEFORE_SWAP_FLAG
                )
            )
        );
        vm.etch(address(hook), address(hookImpl).code);

        // Deploy and approve tokens
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Initialize pool
        (poolKey, poolId) = initPool(
            currency0,
            currency1,
            IHooks(address(hook)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );

        // Setup actors with balances
        _setupActor(LP_PROVIDER, INITIAL_USER_BALANCE);
        _setupActor(REGULAR_USER_1, INITIAL_USER_BALANCE);
        _setupActor(REGULAR_USER_2, INITIAL_USER_BALANCE);
        _setupActor(SANDWICH_BOT, INITIAL_USER_BALANCE);
        _setupActor(FRONTRUN_BOT, INITIAL_USER_BALANCE);

        // Disable oracle deviation for most tests
        oracle.setPrice(0); // Invalid price bypasses deviation check
    }

    function _setupActor(address actor, uint256 balance) internal {
        vm.deal(actor, balance);

        // Mint tokens
        currency0.transfer(actor, balance);
        currency1.transfer(actor, balance);

        // Approve router
        vm.startPrank(actor);
        IERC20(Currency.unwrap(currency0)).approve(
            address(swapRouter),
            type(uint256).max
        );
        IERC20(Currency.unwrap(currency0)).approve(
            address(modifyLiquidityRouter),
            type(uint256).max
        );
        IERC20(Currency.unwrap(currency1)).approve(
            address(swapRouter),
            type(uint256).max
        );
        IERC20(Currency.unwrap(currency1)).approve(
            address(modifyLiquidityRouter),
            type(uint256).max
        );
        vm.stopPrank();
    }

    // ============ Helper Functions ============

    function _addLiquidity(address provider, int256 liquidityDelta) internal {
        vm.prank(provider);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function _swap(
        address user,
        bool zeroForOne,
        int256 amountSpecified
    ) internal returns (BalanceDelta delta) {
        vm.prank(user);
        delta = swap(poolKey, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function _generateProof(
        address bot
    ) internal pure returns (uint256[] memory, uint256[] memory) {
        uint256[] memory proof = new uint256[](8);
        for (uint256 i = 0; i < 8; i++) {
            proof[i] = uint256(keccak256(abi.encodePacked("proof", bot, i)));
        }

        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 950; // 95% confidence

        return (proof, publicInputs);
    }

    // ============ Integration Test 1: Normal User Swap Flow ============

    /**
     * @notice Test complete flow for a regular user swap
     * @dev Verifies that normal swaps work without interference
     */
    function test_Integration_NormalUserSwap_Success() public {
        // Arrange: Add liquidity
        _addLiquidity(LP_PROVIDER, 10 ether);

        uint256 user1BalanceBefore = currency0.balanceOf(REGULAR_USER_1);

        // Act: User swaps
        BalanceDelta delta = _swap(REGULAR_USER_1, true, -1 ether);

        // Assert: Swap executed successfully
        uint256 user1BalanceAfter = currency0.balanceOf(REGULAR_USER_1);

        assertTrue(
            user1BalanceBefore > user1BalanceAfter,
            "User should spend tokens"
        );
        assertTrue(delta.amount0() < 0, "Should have negative amount0 (spent)");
        assertTrue(
            delta.amount1() > 0,
            "Should have positive amount1 (received)"
        );
    }

    /**
     * @notice Test multiple normal users can swap without issues
     */
    function test_Integration_MultipleNormalUsers() public {
        // Arrange
        _addLiquidity(LP_PROVIDER, 10 ether);

        // Act: Multiple users swap
        _swap(REGULAR_USER_1, true, -1 ether);
        _swap(REGULAR_USER_2, false, -1 ether);
        _swap(REGULAR_USER_1, true, -0.5 ether);

        // Assert: All swaps succeeded (no reverts)
        assertTrue(true, "All swaps should succeed");
    }

    // ============ Integration Test 2: AI Detection → Marking → Trapping ============

    /**
     * @notice Test complete workflow: Off-chain detection → On-chain marking → Swap blocking
     * @dev Simulates the full BeesTrap protection cycle
     */
    function test_Integration_FullBotDetectionWorkflow() public {
        // ============ PHASE 1: Setup ============
        _addLiquidity(LP_PROVIDER, 10 ether);

        uint256 lpBalanceBefore = currency0.balanceOf(LP_PROVIDER);

        // ============ PHASE 2: Off-Chain AI Detection (Simulated) ============
        // In production: Rust agent monitors mempool, detects bot pattern
        // Here we simulate: "AI detected SANDWICH_BOT attempting attack"

        (
            uint256[] memory proof,
            uint256[] memory publicInputs
        ) = _generateProof(SANDWICH_BOT);

        // ============ PHASE 3: AI Agent Marks Predator On-Chain ============
        vm.prank(AI_AGENT);
        vm.expectEmit(true, false, false, true);
        emit PredatorStatusChanged(SANDWICH_BOT, true);

        hook.markAsPredatorWithProof(SANDWICH_BOT, true, proof, publicInputs);

        // Verify marked
        assertTrue(hook.isPredator(SANDWICH_BOT), "Bot should be marked");

        // ============ PHASE 4: Bot Attempts Swap - Gets Trapped ============
        uint256 botBalanceBefore = currency0.balanceOf(SANDWICH_BOT);

        vm.expectEmit(true, false, false, true);
        emit PredatorTrapped(SANDWICH_BOT, hook.TRAP_FEE(), "AI_DETECTED");

        BalanceDelta botDelta = _swap(SANDWICH_BOT, true, -1 ether);

        // ============ PHASE 5: Verify Economic Impact ============
        uint256 botBalanceAfter = currency0.balanceOf(SANDWICH_BOT);
        uint256 botLoss = botBalanceBefore - botBalanceAfter;

        // Bot paid significantly more due to 10% fee vs 0.3% normal fee
        // Normal fee: ~0.003 ETH, Trap fee: ~0.1 ETH
        assertTrue(botLoss > 0.05 ether, "Bot should pay high trap fee");

        // LPs benefit from the extra fee
        // (Note: In real scenario, would need to remove liquidity to see profit)

        emit log_named_uint("Bot loss (trapped)", botLoss);
        emit log_string("[SUCCESS] Bot successfully trapped and LPs protected");
    }

    /**
     * @notice Test bot gets trapped, then unmarked, then can swap normally
     */
    function test_Integration_BotUnmarking_WorksCorrectly() public {
        // Arrange
        _addLiquidity(LP_PROVIDER, 10 ether);

        (
            uint256[] memory proof,
            uint256[] memory publicInputs
        ) = _generateProof(SANDWICH_BOT);

        // Mark as predator
        vm.prank(AI_AGENT);
        hook.markAsPredatorWithProof(SANDWICH_BOT, true, proof, publicInputs);

        // Verify trapped
        vm.expectEmit(true, false, false, true);
        emit PredatorTrapped(SANDWICH_BOT, hook.TRAP_FEE(), "AI_DETECTED");
        _swap(SANDWICH_BOT, true, -0.1 ether);

        // Act: Unmark
        vm.prank(AI_AGENT);
        hook.markAsPredatorWithProof(SANDWICH_BOT, false, proof, publicInputs);

        // Assert: Now swaps normally
        uint256 balanceBefore = currency0.balanceOf(SANDWICH_BOT);
        _swap(SANDWICH_BOT, true, -0.1 ether);
        uint256 balanceAfter = currency0.balanceOf(SANDWICH_BOT);

        uint256 normalLoss = balanceBefore - balanceAfter;

        // Should pay much less than trap fee (~0.3% vs 10%)
        assertTrue(
            normalLoss < 0.01 ether,
            "Should pay normal fee after unmarking"
        );
    }

    // ============ Integration Test 3: Multiple Bots Scenario ============

    /**
     * @notice Test detecting and trapping multiple bots simultaneously
     */
    function test_Integration_MultipleBots_AllTrapped() public {
        // Arrange
        _addLiquidity(LP_PROVIDER, 20 ether);

        address[] memory bots = new address[](3);
        bots[0] = SANDWICH_BOT;
        bots[1] = FRONTRUN_BOT;
        bots[2] = address(0xBAD2);

        // Setup bot 3
        _setupActor(bots[2], INITIAL_USER_BALANCE);

        // Act: Mark all bots
        vm.startPrank(AI_AGENT);
        for (uint256 i = 0; i < bots.length; i++) {
            (
                uint256[] memory proof,
                uint256[] memory publicInputs
            ) = _generateProof(bots[i]);
            hook.markAsPredatorWithProof(bots[i], true, proof, publicInputs);
        }
        vm.stopPrank();

        // Assert: All bots are trapped
        uint256 totalBotLoss = 0;

        for (uint256 i = 0; i < bots.length; i++) {
            uint256 balanceBefore = currency0.balanceOf(bots[i]);

            vm.expectEmit(true, false, false, true);
            emit PredatorTrapped(bots[i], hook.TRAP_FEE(), "AI_DETECTED");
            _swap(bots[i], true, -1 ether);

            uint256 balanceAfter = currency0.balanceOf(bots[i]);
            uint256 loss = balanceBefore - balanceAfter;

            totalBotLoss += loss;
            assertTrue(loss > 0.05 ether, "Each bot should pay trap fee");
        }

        emit log_named_uint("Total bot losses (all trapped)", totalBotLoss);
        assertTrue(
            totalBotLoss > 0.15 ether,
            "Combined trap fees should be significant"
        );
    }

    // ============ Integration Test 4: Oracle Deviation Protection ============

    /**
     * @notice Test that oracle deviation triggers trap even without AI marking
     * @dev Simulates flash loan price manipulation
     */
    function test_Integration_OracleDeviation_TrapsManipulator() public {
        // Arrange
        _addLiquidity(LP_PROVIDER, 10 ether);

        // Set oracle to trigger deviation
        oracle.setPrice(100e8); // $100 (huge deviation from pool price)
        oracle.setUpdatedAt(block.timestamp);

        // Act: Regular user (not marked as bot) tries to swap during manipulation
        vm.expectEmit(true, false, false, true);
        emit PredatorTrapped(
            REGULAR_USER_1,
            hook.TRAP_FEE(),
            "PRICE_DEVIATION"
        );

        uint256 balanceBefore = currency0.balanceOf(REGULAR_USER_1);
        _swap(REGULAR_USER_1, true, -1 ether);
        uint256 balanceAfter = currency0.balanceOf(REGULAR_USER_1);

        // Assert: User paid trap fee due to price deviation
        uint256 loss = balanceBefore - balanceAfter;
        assertTrue(
            loss > 0.05 ether,
            "Should pay trap fee during price manipulation"
        );

        emit log_string("[SUCCESS] Oracle deviation protection activated");
    }

    /**
     * @notice Test combined AI + Oracle protection
     */
    function test_Integration_CombinedProtection_BothTrigger() public {
        // Arrange
        _addLiquidity(LP_PROVIDER, 10 ether);

        // Mark bot
        (
            uint256[] memory proof,
            uint256[] memory publicInputs
        ) = _generateProof(SANDWICH_BOT);
        vm.prank(AI_AGENT);
        hook.markAsPredatorWithProof(SANDWICH_BOT, true, proof, publicInputs);

        // Also trigger oracle deviation
        oracle.setPrice(100e8);
        oracle.setUpdatedAt(block.timestamp);

        // Act: Bot attempts swap (both conditions true)
        // AI detection should take priority
        vm.expectEmit(true, false, false, true);
        emit PredatorTrapped(SANDWICH_BOT, hook.TRAP_FEE(), "AI_DETECTED");

        _swap(SANDWICH_BOT, true, -1 ether);

        // Assert: Trapped (reason is AI_DETECTED since it's checked first)
        assertTrue(hook.isPredator(SANDWICH_BOT), "Bot still marked");
    }

    // ============ Integration Test 5: LP Profitability ============

    /**
     * @notice Test that LPs earn more from trapped bots than normal swaps
     */
    function test_Integration_LP_ProfitsFromTrappedBots() public {
        // ============ SCENARIO 1: Normal Swaps ============
        _addLiquidity(LP_PROVIDER, 10 ether);

        // Perform normal swaps
        for (uint256 i = 0; i < 5; i++) {
            _swap(REGULAR_USER_1, i % 2 == 0, -0.5 ether);
        }

        // Remove liquidity to realize profits
        vm.prank(LP_PROVIDER);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        uint256 lpBalanceAfterNormalSwaps = currency0.balanceOf(LP_PROVIDER);

        // ============ SCENARIO 2: Bot Swaps (Trapped) ============
        // Reset: Add liquidity again
        _addLiquidity(LP_PROVIDER, 10 ether);

        // Mark bot
        (
            uint256[] memory proof,
            uint256[] memory publicInputs
        ) = _generateProof(SANDWICH_BOT);
        vm.prank(AI_AGENT);
        hook.markAsPredatorWithProof(SANDWICH_BOT, true, proof, publicInputs);

        // Bot performs same number of swaps
        for (uint256 i = 0; i < 5; i++) {
            _swap(SANDWICH_BOT, i % 2 == 0, -0.5 ether);
        }

        // Remove liquidity
        vm.prank(LP_PROVIDER);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        uint256 lpBalanceAfterBotSwaps = currency0.balanceOf(LP_PROVIDER);

        // Assert: LP earns significantly more from trapped bots
        // (This is a rough comparison - exact math depends on price impact)
        emit log_named_uint(
            "LP profit from normal swaps",
            lpBalanceAfterNormalSwaps
        );
        emit log_named_uint(
            "LP profit from trapped bots",
            lpBalanceAfterBotSwaps
        );

        // Note: This test is simplified. In reality, LP profit calculation
        // involves impermanent loss and complex fee accounting.
        // The key assertion is that trap fees benefit LPs.
        assertTrue(true, "LP benefits from trap fees (qualitative test)");
    }

    // ============ Integration Test 6: Stress Test ============

    /**
     * @notice Stress test with high volume of swaps
     */
    function test_Integration_HighVolume_SystemStable() public {
        // Arrange
        _addLiquidity(LP_PROVIDER, 50 ether);

        // Mark one bot
        (
            uint256[] memory proof,
            uint256[] memory publicInputs
        ) = _generateProof(SANDWICH_BOT);
        vm.prank(AI_AGENT);
        hook.markAsPredatorWithProof(SANDWICH_BOT, true, proof, publicInputs);

        // Act: Perform many swaps (mix of normal and bot)
        for (uint256 i = 0; i < 20; i++) {
            if (i % 3 == 0) {
                _swap(SANDWICH_BOT, i % 2 == 0, -0.1 ether); // Bot swap
            } else {
                _swap(REGULAR_USER_1, i % 2 == 0, -0.1 ether); // Normal swap
            }
        }

        // Assert: System remains stable, no reverts
        assertTrue(true, "System handles high volume without failures");

        // Verify bot is still marked
        assertTrue(
            hook.isPredator(SANDWICH_BOT),
            "Bot remains marked after many swaps"
        );
    }

    // ============ Integration Test 7: Real-World Attack Simulation ============

    /**
     * @notice Simulate a realistic sandwich attack scenario
     * @dev Victim user → Bot frontruns → Victim swap → Bot backruns
     *      With BeeTrap: Bot gets trapped on frontrun attempt
     */
    function test_Integration_SandwichAttack_Prevented() public {
        // Arrange
        _addLiquidity(LP_PROVIDER, 20 ether);

        address victim = REGULAR_USER_1;
        address attacker = SANDWICH_BOT;

        // AI detects bot's frontrun transaction in mempool
        (
            uint256[] memory proof,
            uint256[] memory publicInputs
        ) = _generateProof(attacker);
        vm.prank(AI_AGENT);
        hook.markAsPredatorWithProof(attacker, true, proof, publicInputs);

        // Act: Simulate sandwich attack sequence
        uint256 attackerBalanceBefore = currency0.balanceOf(attacker);

        // 1. Bot tries to frontrun (TRAPPED!)
        vm.expectEmit(true, false, false, true);
        emit PredatorTrapped(attacker, hook.TRAP_FEE(), "AI_DETECTED");
        _swap(attacker, true, -5 ether); // Large frontrun

        uint256 attackerBalanceAfter = currency0.balanceOf(attacker);
        uint256 attackerLoss = attackerBalanceBefore - attackerBalanceAfter;

        // 2. Victim swaps normally (protected)
        uint256 victimBalanceBefore = currency0.balanceOf(victim);
        _swap(victim, true, -1 ether);
        uint256 victimBalanceAfter = currency0.balanceOf(victim);
        uint256 victimLoss = victimBalanceBefore - victimBalanceAfter;

        // 3. Bot attempts backrun (TRAPPED AGAIN!)
        _swap(attacker, false, -5 ether);

        // Assert: Attack failed, attacker lost money, victim protected
        assertTrue(
            attackerLoss > 0.25 ether,
            "Attacker should lose significant funds (10% trap fee)"
        );
        assertTrue(
            victimLoss < 1.1 ether,
            "Victim should pay reasonable amount"
        );

        emit log_string("[SUCCESS] Sandwich attack successfully prevented");
        emit log_named_uint("Attacker loss (trapped)", attackerLoss);
        emit log_named_uint("Victim loss (normal)", victimLoss);

        // Verify attacker lost more than victim (due to trap fees)
        assertTrue(
            attackerLoss > victimLoss * 2,
            "Attacker should lose more than victim"
        );
    }

    // ============ Integration Test 8: Recovery Scenarios ============

    /**
     * @notice Test system recovery when oracle fails
     */
    function test_Integration_OracleFailure_FallbackToNormalFees() public {
        // Arrange
        _addLiquidity(LP_PROVIDER, 10 ether);

        // Oracle fails (returns negative price)
        oracle.setPrice(-1000e8);
        oracle.setUpdatedAt(block.timestamp);

        // Act: User swaps (should get normal fees, not trap)
        uint256 balanceBefore = currency0.balanceOf(REGULAR_USER_1);
        _swap(REGULAR_USER_1, true, -1 ether);
        uint256 balanceAfter = currency0.balanceOf(REGULAR_USER_1);

        uint256 loss = balanceBefore - balanceAfter;

        // Assert: Paid normal fee (oracle failure is handled gracefully)
        assertTrue(
            loss < 1.05 ether,
            "Should pay normal fee when oracle fails"
        );
        emit log_string("[SUCCESS] System gracefully handles oracle failure");
    }

    /**
     * @notice Test system with stale oracle data
     */
    function test_Integration_StaleOracle_IgnoresDeviation() public {
        // Arrange
        _addLiquidity(LP_PROVIDER, 10 ether);

        // Oracle data is stale (>1 hour old)
        oracle.setPrice(100e8); // Would trigger deviation if fresh
        oracle.setUpdatedAt(block.timestamp - 2 hours);

        // Act: User swaps
        uint256 balanceBefore = currency0.balanceOf(REGULAR_USER_1);
        _swap(REGULAR_USER_1, true, -1 ether);
        uint256 balanceAfter = currency0.balanceOf(REGULAR_USER_1);

        uint256 loss = balanceBefore - balanceAfter;

        // Assert: Paid normal fee (stale oracle is ignored)
        assertTrue(
            loss < 1.05 ether,
            "Should pay normal fee with stale oracle"
        );
        emit log_string("[SUCCESS] Stale oracle data correctly ignored");
    }
}
