// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {BeeTrapHook, AggregatorV3Interface, IVerifier} from "../src/BeeTrapHook.sol";
import {MockVerifier, MockHalo2Verifier} from "./mocks/MockVerifier.sol";

// Import MockOracle from original test file
contract MockOracle is AggregatorV3Interface {
    int256 private _price;
    uint256 private _updatedAt;
    uint8 private constant DECIMALS = 8;

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
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, _price, _updatedAt, _updatedAt, 1);
    }

    function decimals() external pure override returns (uint8) {
        return DECIMALS;
    }
}

/**
 * @title BeeTrapHookWithVerifierTest
 * @notice Comprehensive tests for ZK proof verification in BeeTrapHook
 * @dev Tests the integration of EZKL-generated ZK proofs with the hook contract
 */
contract BeeTrapHookWithVerifierTest is Test, Deployers {
    // ============ Test Addresses ============
    address constant AI_AGENT = address(0x1337);
    address constant PREDATOR_BOT = address(0xDEAD);
    address constant REGULAR_USER = address(0xBEEF);
    int256 constant INITIAL_ORACLE_PRICE = 3000e8;

    // ============ Contracts ============
    MockOracle oracle;
    MockVerifier simpleVerifier;
    MockHalo2Verifier halo2Verifier;
    BeeTrapHook hookWithSimpleVerifier;
    BeeTrapHook hookWithHalo2Verifier;
    PoolKey poolKey;

    // ============ Events ============
    event PredatorStatusChanged(address indexed bot, bool status);
    event PredatorTrapped(
        address indexed predator,
        uint24 feeApplied,
        string reason
    );

    // ============ Setup ============
    function setUp() public {
        // Deploy oracle
        oracle = new MockOracle(INITIAL_ORACLE_PRICE);

        // Deploy Uniswap infrastructure
        deployFreshManagerAndRouters();

        // Deploy both verifier types
        simpleVerifier = new MockVerifier(true); // Default: proofs pass
        halo2Verifier = new MockHalo2Verifier(false); // Default: non-strict mode

        // Deploy hooks with different verifiers
        // hookWithSimpleVerifier deployed via etch below

        hookWithHalo2Verifier = new BeeTrapHook(
            manager,
            AI_AGENT,
            AggregatorV3Interface(address(oracle)),
            IVerifier(address(halo2Verifier))
        );

        // Deploy implementation
        BeeTrapHook implementation = new BeeTrapHook(
            manager,
            AI_AGENT,
            AggregatorV3Interface(address(oracle)),
            IVerifier(address(simpleVerifier))
        );

        // Etch to valid address
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG |
                    (uint256(type(uint160).max) & clearAllHookPermissionsMask)
            )
        );
        vm.etch(hookAddress, address(implementation).code);
        hookWithSimpleVerifier = BeeTrapHook(hookAddress);

        // Initialize pool with simple verifier hook
        (currency0, currency1) = deployMintAndApprove2Currencies();
        (poolKey, ) = initPool(
            currency0,
            currency1,
            IHooks(address(hookWithSimpleVerifier)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );

        // Note: hookWithHalo2Verifier is not etched here, so tests using it might fail if they init pool
        // But the tests use it for markAsPredatorWithProof only?
        // Let's create a second address for it if needed.
        BeeTrapHook implementation2 = new BeeTrapHook(
            manager,
            AI_AGENT,
            AggregatorV3Interface(address(oracle)),
            IVerifier(address(halo2Verifier))
        );
        // Use a slight variation (e.g. different salt if mining, but here we construct address)
        // We can't have two hooks with same permissions at same address.
        // For unit tests of `markAsPredatorWithProof`, the hook address doesn't strict matter for the CALL,
        // but verifyCallCount checks might rely on it.
        // Actually `markAsPredatorWithProof` doesn't check hook flags. V4 Manager checks flags at initialization and swap.
        // So `hookWithHalo2Verifier` can be a normal deployment IF it is NOT used in `initPool`.
        hookWithHalo2Verifier = implementation2;
    }

    // ============ Helper Functions ============

    /**
     * @notice Generate a mock proof array
     */
    function _generateMockProof() internal pure returns (uint256[] memory) {
        uint256[] memory proof = new uint256[](8);
        for (uint256 i = 0; i < 8; i++) {
            proof[i] = uint256(keccak256(abi.encodePacked("proof", i)));
        }
        return proof;
    }

    /**
     * @notice Generate mock public inputs (normalized features)
     */
    function _generateMockPublicInputs(
        address bot
    ) internal pure returns (uint256[] memory) {
        uint256[] memory inputs = new uint256[](1);
        // Simulate the probability output (e.g., 0.95 as fixed-point)
        inputs[0] = uint256(keccak256(abi.encodePacked(bot))) % 1000; // 0-999 range
        return inputs;
    }

    // ============ Basic Verifier Integration Tests ============

    /**
     * @notice Test marking predator with valid ZK proof succeeds
     */
    function test_MarkWithProof_ValidProof_Success() public {
        // Arrange
        uint256[] memory proof = _generateMockProof();
        uint256[] memory publicInputs = _generateMockPublicInputs(PREDATOR_BOT);

        // Verifier is set to return true
        assertEq(simpleVerifier.shouldVerify(), true);

        // Act
        vm.prank(AI_AGENT);
        vm.expectEmit(true, false, false, true);
        emit PredatorStatusChanged(PREDATOR_BOT, true);

        hookWithSimpleVerifier.markAsPredatorWithProof(
            PREDATOR_BOT,
            true,
            proof,
            publicInputs
        );

        // Assert
        assertTrue(
            hookWithSimpleVerifier.isPredator(PREDATOR_BOT),
            "Bot should be marked as predator"
        );
        assertEq(
            simpleVerifier.verifyCallCount(),
            1,
            "Verifier should be called once"
        );
    }

    /**
     * @notice Test marking predator with invalid ZK proof fails
     */
    function test_MarkWithProof_InvalidProof_Reverts() public {
        // Arrange
        simpleVerifier.setShouldVerify(false); // Make verifier reject proofs

        uint256[] memory proof = _generateMockProof();
        uint256[] memory publicInputs = _generateMockPublicInputs(PREDATOR_BOT);

        // Act & Assert
        vm.prank(AI_AGENT);
        vm.expectRevert(BeeTrapHook.InvalidZKProof.selector);

        hookWithSimpleVerifier.markAsPredatorWithProof(
            PREDATOR_BOT,
            true,
            proof,
            publicInputs
        );

        // Bot should NOT be marked
        assertFalse(
            hookWithSimpleVerifier.isPredator(PREDATOR_BOT),
            "Bot should NOT be marked with invalid proof"
        );
    }

    /**
     * @notice Test that only AI agent can submit proofs
     */
    function test_MarkWithProof_OnlyAIAgent() public {
        // Arrange
        uint256[] memory proof = _generateMockProof();
        uint256[] memory publicInputs = _generateMockPublicInputs(PREDATOR_BOT);

        // Act & Assert
        vm.prank(REGULAR_USER);
        vm.expectRevert(BeeTrapHook.OnlyAIAgent.selector);

        hookWithSimpleVerifier.markAsPredatorWithProof(
            PREDATOR_BOT,
            true,
            proof,
            publicInputs
        );
    }

    /**
     * @notice Test unmarking predator with proof
     */
    function test_MarkWithProof_UnmarkPredator() public {
        // Arrange: First mark as predator
        uint256[] memory proof = _generateMockProof();
        uint256[] memory publicInputs = _generateMockPublicInputs(PREDATOR_BOT);

        vm.prank(AI_AGENT);
        hookWithSimpleVerifier.markAsPredatorWithProof(
            PREDATOR_BOT,
            true,
            proof,
            publicInputs
        );
        assertTrue(hookWithSimpleVerifier.isPredator(PREDATOR_BOT));

        // Act: Unmark with proof
        vm.prank(AI_AGENT);
        vm.expectEmit(true, false, false, true);
        emit PredatorStatusChanged(PREDATOR_BOT, false);

        hookWithSimpleVerifier.markAsPredatorWithProof(
            PREDATOR_BOT,
            false,
            proof,
            publicInputs
        );

        // Assert
        assertFalse(
            hookWithSimpleVerifier.isPredator(PREDATOR_BOT),
            "Bot should be unmarked"
        );
    }

    // ============ Halo2 Verifier Specific Tests ============

    /**
     * @notice Test with realistic Halo2 verifier in strict mode
     */
    function test_Halo2Verifier_StrictMode_ValidStructure() public {
        // Arrange: Enable strict mode
        halo2Verifier.setStrictMode(true);

        // Generate valid proof (8 elements, all non-zero)
        uint256[] memory proof = _generateMockProof();
        uint256[] memory publicInputs = _generateMockPublicInputs(PREDATOR_BOT);

        // Register this proof as valid
        halo2Verifier.registerValidProof(proof, publicInputs);

        // Act
        vm.prank(AI_AGENT);
        hookWithHalo2Verifier.markAsPredatorWithProof(
            PREDATOR_BOT,
            true,
            proof,
            publicInputs
        );

        // Assert
        assertTrue(
            hookWithHalo2Verifier.isPredator(PREDATOR_BOT),
            "Should mark with valid Halo2 proof"
        );
    }

    /**
     * @notice Test Halo2 verifier rejects invalid proof length
     */
    function test_Halo2Verifier_StrictMode_InvalidProofLength() public {
        // Arrange: Enable strict mode
        halo2Verifier.setStrictMode(true);

        // Generate INVALID proof (wrong length)
        uint256[] memory invalidProof = new uint256[](5); // Should be 8
        for (uint256 i = 0; i < 5; i++) {
            invalidProof[i] = uint256(keccak256(abi.encodePacked("proof", i)));
        }

        uint256[] memory publicInputs = _generateMockPublicInputs(PREDATOR_BOT);

        // Act & Assert
        vm.prank(AI_AGENT);
        vm.expectRevert(BeeTrapHook.InvalidZKProof.selector);

        hookWithHalo2Verifier.markAsPredatorWithProof(
            PREDATOR_BOT,
            true,
            invalidProof,
            publicInputs
        );
    }

    /**
     * @notice Test Halo2 verifier rejects proof with zero elements
     */
    function test_Halo2Verifier_StrictMode_ZeroElements() public {
        // Arrange
        halo2Verifier.setStrictMode(true);

        uint256[] memory invalidProof = new uint256[](8);
        invalidProof[0] = 123;
        invalidProof[1] = 0; // Invalid: contains zero
        for (uint256 i = 2; i < 8; i++) {
            invalidProof[i] = uint256(keccak256(abi.encodePacked("proof", i)));
        }

        uint256[] memory publicInputs = _generateMockPublicInputs(PREDATOR_BOT);

        // Act & Assert
        vm.prank(AI_AGENT);
        vm.expectRevert(BeeTrapHook.InvalidZKProof.selector);

        hookWithHalo2Verifier.markAsPredatorWithProof(
            PREDATOR_BOT,
            true,
            invalidProof,
            publicInputs
        );
    }

    /**
     * @notice Test Halo2 verifier rejects unregistered proofs
     */
    function test_Halo2Verifier_UnregisteredProof_Fails() public {
        // Arrange: Valid structure but not registered
        uint256[] memory proof = _generateMockProof();
        uint256[] memory publicInputs = _generateMockPublicInputs(PREDATOR_BOT);

        // Don't register the proof
        halo2Verifier.setStrictMode(false);

        // Act & Assert
        vm.prank(AI_AGENT);
        vm.expectRevert(BeeTrapHook.InvalidZKProof.selector);

        hookWithHalo2Verifier.markAsPredatorWithProof(
            PREDATOR_BOT,
            true,
            proof,
            publicInputs
        );
    }

    // ============ Multiple Predator Tests ============

    /**
     * @notice Test marking multiple predators with different proofs
     */
    function test_MarkMultiplePredators_WithDifferentProofs() public {
        address predator1 = address(0xDEAD);
        address predator2 = address(0xBEEF);
        address predator3 = address(0xCAFE);

        // Generate different proofs for each
        uint256[] memory proof1 = _generateMockPublicInputs(predator1);
        uint256[] memory proof2 = _generateMockPublicInputs(predator2);
        uint256[] memory proof3 = _generateMockPublicInputs(predator3);

        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = 950; // High confidence

        // Mark all three
        vm.startPrank(AI_AGENT);

        hookWithSimpleVerifier.markAsPredatorWithProof(
            predator1,
            true,
            proof1,
            publicInputs
        );
        hookWithSimpleVerifier.markAsPredatorWithProof(
            predator2,
            true,
            proof2,
            publicInputs
        );
        hookWithSimpleVerifier.markAsPredatorWithProof(
            predator3,
            true,
            proof3,
            publicInputs
        );

        vm.stopPrank();

        // Assert all marked
        assertTrue(hookWithSimpleVerifier.isPredator(predator1));
        assertTrue(hookWithSimpleVerifier.isPredator(predator2));
        assertTrue(hookWithSimpleVerifier.isPredator(predator3));

        // Verify call count
        assertEq(simpleVerifier.verifyCallCount(), 3, "Should verify 3 proofs");
    }

    // ============ Proof Storage Tests ============

    /**
     * @notice Test that verifier stores last proof for debugging
     */
    function test_Verifier_StoresLastProof() public {
        // Arrange
        uint256[] memory proof = _generateMockProof();
        uint256[] memory publicInputs = _generateMockPublicInputs(PREDATOR_BOT);

        // Act
        vm.prank(AI_AGENT);
        hookWithSimpleVerifier.markAsPredatorWithProof(
            PREDATOR_BOT,
            true,
            proof,
            publicInputs
        );

        // Assert: Check stored proof matches
        uint256[] memory storedProof = simpleVerifier.getLastProof();
        uint256[] memory storedInputs = simpleVerifier.getLastPublicInputs();

        assertEq(
            storedProof.length,
            proof.length,
            "Stored proof length mismatch"
        );
        assertEq(
            storedInputs.length,
            publicInputs.length,
            "Stored inputs length mismatch"
        );

        for (uint256 i = 0; i < proof.length; i++) {
            assertEq(storedProof[i], proof[i], "Stored proof element mismatch");
        }
    }

    // ============ Edge Case Tests ============

    /**
     * @notice Test with empty proof array
     */
    function test_MarkWithProof_EmptyProof() public {
        // Arrange
        uint256[] memory emptyProof = new uint256[](0);
        uint256[] memory publicInputs = _generateMockPublicInputs(PREDATOR_BOT);

        // Set verifier to reject to simulate invalid proof
        simpleVerifier.setShouldVerify(false);

        vm.prank(AI_AGENT);
        vm.expectRevert(BeeTrapHook.InvalidZKProof.selector);
        hookWithSimpleVerifier.markAsPredatorWithProof(
            PREDATOR_BOT,
            true,
            emptyProof,
            publicInputs
        );
    }

    /**
     * @notice Test with empty public inputs
     */
    function test_MarkWithProof_EmptyPublicInputs() public {
        // Arrange
        uint256[] memory proof = _generateMockProof();
        uint256[] memory emptyInputs = new uint256[](0);

        // Set verifier to reject
        simpleVerifier.setShouldVerify(false);

        vm.prank(AI_AGENT);
        vm.expectRevert(BeeTrapHook.InvalidZKProof.selector);
        hookWithSimpleVerifier.markAsPredatorWithProof(
            PREDATOR_BOT,
            true,
            proof,
            emptyInputs
        );
    }

    /**
     * @notice Test marking same predator multiple times with different proofs
     */
    function test_MarkSamePredator_MultipleTimes() public {
        // Arrange
        uint256[] memory proof1 = _generateMockProof();
        uint256[] memory proof2 = _generateMockPublicInputs(PREDATOR_BOT);
        uint256[] memory publicInputs = _generateMockPublicInputs(PREDATOR_BOT);

        vm.startPrank(AI_AGENT);

        // Act: Mark twice
        hookWithSimpleVerifier.markAsPredatorWithProof(
            PREDATOR_BOT,
            true,
            proof1,
            publicInputs
        );
        hookWithSimpleVerifier.markAsPredatorWithProof(
            PREDATOR_BOT,
            true,
            proof2,
            publicInputs
        );

        vm.stopPrank();

        // Assert: Still marked, verified twice
        assertTrue(hookWithSimpleVerifier.isPredator(PREDATOR_BOT));
        assertEq(simpleVerifier.verifyCallCount(), 2);
    }

    // ============ Verifier State Tests ============

    /**
     * @notice Test toggling verifier result mid-test
     */
    function test_VerifierToggle_AffectsMarking() public {
        // Arrange
        uint256[] memory proof = _generateMockProof();
        uint256[] memory publicInputs = _generateMockPublicInputs(PREDATOR_BOT);

        // First mark succeeds
        vm.prank(AI_AGENT);
        hookWithSimpleVerifier.markAsPredatorWithProof(
            PREDATOR_BOT,
            true,
            proof,
            publicInputs
        );
        assertTrue(hookWithSimpleVerifier.isPredator(PREDATOR_BOT));

        // Toggle verifier to reject
        simpleVerifier.setShouldVerify(false);

        // Unmark should now fail
        vm.prank(AI_AGENT);
        vm.expectRevert(BeeTrapHook.InvalidZKProof.selector);
        hookWithSimpleVerifier.markAsPredatorWithProof(
            PREDATOR_BOT,
            false,
            proof,
            publicInputs
        );

        // Still marked (unmark failed)
        assertTrue(hookWithSimpleVerifier.isPredator(PREDATOR_BOT));
    }

    /**
     * @notice Test verifier call count increments correctly
     */
    function test_VerifierCallCount() public {
        // Arrange
        uint256[] memory proof = _generateMockProof();
        uint256[] memory publicInputs = _generateMockPublicInputs(PREDATOR_BOT);

        assertEq(simpleVerifier.verifyCallCount(), 0);

        // Act: Multiple calls
        vm.startPrank(AI_AGENT);
        hookWithSimpleVerifier.markAsPredatorWithProof(
            PREDATOR_BOT,
            true,
            proof,
            publicInputs
        );
        assertEq(simpleVerifier.verifyCallCount(), 1);

        hookWithSimpleVerifier.markAsPredatorWithProof(
            PREDATOR_BOT,
            false,
            proof,
            publicInputs
        );
        assertEq(simpleVerifier.verifyCallCount(), 2);

        hookWithSimpleVerifier.markAsPredatorWithProof(
            PREDATOR_BOT,
            true,
            proof,
            publicInputs
        );
        assertEq(simpleVerifier.verifyCallCount(), 3);

        vm.stopPrank();
    }
}
