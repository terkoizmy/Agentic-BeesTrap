// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {AgentNFT} from "../src/AgentNFT.sol";
import {ValidationRegistry, IZKVerifier} from "../src/ValidationRegistry.sol";

/**
 * @title MockZKVerifier
 * @notice Mock implementation of IZKVerifier for testing
 */
contract MockZKVerifier is IZKVerifier {
    bool public shouldPass;

    constructor(bool _shouldPass) {
        shouldPass = _shouldPass;
    }

    function setShouldPass(bool _shouldPass) external {
        shouldPass = _shouldPass;
    }

    function verify(
        bytes calldata,
        bytes32[] calldata
    ) external view override returns (bool) {
        return shouldPass;
    }
}

/**
 * @title ValidationRegistryTest
 * @notice Comprehensive unit tests for the ValidationRegistry contract
 */
contract ValidationRegistryTest is Test {
    AgentNFT public nft;
    ValidationRegistry public registry;
    MockZKVerifier public zkVerifier;

    address public owner = address(this);
    address public nftHolder = address(0xBEEF);
    address public executor;
    uint256 public executorPrivateKey;
    address public otherUser = address(0xDEAD);

    bytes32 constant MODEL_HASH = keccak256("beetrap_model.onnx");
    string constant TEST_URI = "ipfs://QmAgent";

    uint256 public agentId;

    // Events
    event AgentRegistered(
        uint256 indexed nftId,
        bytes32 modelHash,
        address executor,
        ValidationRegistry.ValidationMode mode
    );
    event AgentUpgradedToEZKL(uint256 indexed nftId, address zkVerifier);
    event AgentDeactivated(uint256 indexed nftId);
    event AgentActivated(uint256 indexed nftId);
    event DetectionVerified(
        uint256 indexed nftId,
        address indexed targetBot,
        uint256 timestamp,
        ValidationRegistry.ValidationMode mode
    );

    function setUp() public {
        // Create executor with private key for signing
        executorPrivateKey = 0xBEEF;
        executor = vm.addr(executorPrivateKey);

        // Deploy contracts
        address verifier = address(0xDEAD);
        nft = new AgentNFT(owner, verifier);
        registry = new ValidationRegistry(address(nft));
        zkVerifier = new MockZKVerifier(true);

        // Mint an agent NFT to the holder
        agentId = nft.mint(nftHolder, TEST_URI);
    }

    // ============ Registration Tests ============

    function test_RegisterAgent_Success() public {
        vm.prank(nftHolder);

        vm.expectEmit(true, false, false, true);
        emit AgentRegistered(
            agentId,
            MODEL_HASH,
            executor,
            ValidationRegistry.ValidationMode.SIGNATURE
        );

        registry.registerAgent(agentId, MODEL_HASH, executor);

        ValidationRegistry.AgentConfig memory config = registry.getAgentConfig(
            agentId
        );
        assertEq(config.modelHash, MODEL_HASH);
        assertEq(config.executor, executor);
        assertEq(config.zkVerifier, address(0));
        assertTrue(config.mode == ValidationRegistry.ValidationMode.SIGNATURE);
        assertTrue(config.isActive);
    }

    function test_RegisterAgent_RevertIfNotOwner() public {
        vm.prank(otherUser);
        vm.expectRevert(ValidationRegistry.NotNFTOwner.selector);
        registry.registerAgent(agentId, MODEL_HASH, executor);
    }

    function test_RegisterAgent_CanUpdate() public {
        vm.startPrank(nftHolder);

        registry.registerAgent(agentId, MODEL_HASH, executor);

        bytes32 newModelHash = keccak256("new_model.onnx");
        address newExecutor = address(0x1234);

        registry.registerAgent(agentId, newModelHash, newExecutor);

        ValidationRegistry.AgentConfig memory config = registry.getAgentConfig(
            agentId
        );
        assertEq(config.modelHash, newModelHash);
        assertEq(config.executor, newExecutor);

        vm.stopPrank();
    }

    // ============ EZKL Upgrade Tests ============

    function test_UpdateToEZKL_Success() public {
        vm.startPrank(nftHolder);
        registry.registerAgent(agentId, MODEL_HASH, executor);

        vm.expectEmit(true, false, false, true);
        emit AgentUpgradedToEZKL(agentId, address(zkVerifier));

        registry.updateToEZKL(agentId, address(zkVerifier));

        ValidationRegistry.AgentConfig memory config = registry.getAgentConfig(
            agentId
        );
        assertEq(config.zkVerifier, address(zkVerifier));
        assertTrue(config.mode == ValidationRegistry.ValidationMode.EZKL_PROOF);

        vm.stopPrank();
    }

    function test_UpdateToEZKL_RevertIfNotOwner() public {
        vm.prank(nftHolder);
        registry.registerAgent(agentId, MODEL_HASH, executor);

        vm.prank(otherUser);
        vm.expectRevert(ValidationRegistry.NotNFTOwner.selector);
        registry.updateToEZKL(agentId, address(zkVerifier));
    }

    function test_UpdateToEZKL_RevertIfNotRegistered() public {
        vm.prank(nftHolder);
        vm.expectRevert(ValidationRegistry.AgentNotRegistered.selector);
        registry.updateToEZKL(agentId, address(zkVerifier));
    }

    function test_UpdateToEZKL_RevertIfZeroAddress() public {
        vm.startPrank(nftHolder);
        registry.registerAgent(agentId, MODEL_HASH, executor);

        vm.expectRevert(ValidationRegistry.InvalidVerifierAddress.selector);
        registry.updateToEZKL(agentId, address(0));
        vm.stopPrank();
    }

    function test_UpdateToEZKL_RevertIfAlreadyEZKL() public {
        vm.startPrank(nftHolder);
        registry.registerAgent(agentId, MODEL_HASH, executor);
        registry.updateToEZKL(agentId, address(zkVerifier));

        vm.expectRevert(ValidationRegistry.AlreadyInEZKLMode.selector);
        registry.updateToEZKL(agentId, address(zkVerifier));
        vm.stopPrank();
    }

    // ============ Activation Tests ============

    function test_DeactivateAgent_Success() public {
        vm.startPrank(nftHolder);
        registry.registerAgent(agentId, MODEL_HASH, executor);

        vm.expectEmit(true, false, false, false);
        emit AgentDeactivated(agentId);

        registry.deactivateAgent(agentId);

        assertFalse(registry.isAgentActive(agentId));
        vm.stopPrank();
    }

    function test_ActivateAgent_Success() public {
        vm.startPrank(nftHolder);
        registry.registerAgent(agentId, MODEL_HASH, executor);
        registry.deactivateAgent(agentId);

        vm.expectEmit(true, false, false, false);
        emit AgentActivated(agentId);

        registry.activateAgent(agentId);

        assertTrue(registry.isAgentActive(agentId));
        vm.stopPrank();
    }

    // ============ Signature Verification Tests ============

    function test_VerifyDetection_ValidSignature() public {
        vm.prank(nftHolder);
        registry.registerAgent(agentId, MODEL_HASH, executor);

        address targetBot = address(0xBAD);
        uint256 timestamp = block.timestamp;

        // Create signature
        bytes memory signature = _signDetection(
            targetBot,
            timestamp,
            MODEL_HASH,
            executorPrivateKey
        );

        // Verify
        bool isValid = registry.verifyDetection(
            agentId,
            targetBot,
            timestamp,
            signature
        );
        assertTrue(isValid);
    }

    function test_VerifyDetection_InvalidSignature_WrongSigner() public {
        vm.prank(nftHolder);
        registry.registerAgent(agentId, MODEL_HASH, executor);

        address targetBot = address(0xBAD);
        uint256 timestamp = block.timestamp;

        // Sign with wrong key
        uint256 wrongKey = 0xDEAD;
        bytes memory signature = _signDetection(
            targetBot,
            timestamp,
            MODEL_HASH,
            wrongKey
        );

        // Verify should return false
        bool isValid = registry.verifyDetection(
            agentId,
            targetBot,
            timestamp,
            signature
        );
        assertFalse(isValid);
    }

    function test_VerifyDetection_InvalidSignature_WrongTarget() public {
        vm.prank(nftHolder);
        registry.registerAgent(agentId, MODEL_HASH, executor);

        address targetBot = address(0xBAD);
        address wrongTarget = address(0x1234);
        uint256 timestamp = block.timestamp;

        // Sign for wrong target
        bytes memory signature = _signDetection(
            wrongTarget,
            timestamp,
            MODEL_HASH,
            executorPrivateKey
        );

        // Verify with correct target should fail
        bool isValid = registry.verifyDetection(
            agentId,
            targetBot,
            timestamp,
            signature
        );
        assertFalse(isValid);
    }

    function test_VerifyDetection_ExpiredTimestamp() public {
        vm.prank(nftHolder);
        registry.registerAgent(agentId, MODEL_HASH, executor);

        address targetBot = address(0xBAD);
        uint256 oldTimestamp = block.timestamp;

        bytes memory signature = _signDetection(
            targetBot,
            oldTimestamp,
            MODEL_HASH,
            executorPrivateKey
        );

        // Warp time forward past MAX_DETECTION_AGE
        vm.warp(block.timestamp + 6 minutes);

        vm.expectRevert(ValidationRegistry.DetectionExpired.selector);
        registry.verifyDetection(agentId, targetBot, oldTimestamp, signature);
    }

    function test_VerifyDetection_RevertIfNotRegistered() public {
        address targetBot = address(0xBAD);
        uint256 timestamp = block.timestamp;
        bytes memory signature = _signDetection(
            targetBot,
            timestamp,
            MODEL_HASH,
            executorPrivateKey
        );

        vm.expectRevert(ValidationRegistry.AgentNotRegistered.selector);
        registry.verifyDetection(agentId, targetBot, timestamp, signature);
    }

    function test_VerifyDetection_RevertIfNotActive() public {
        vm.startPrank(nftHolder);
        registry.registerAgent(agentId, MODEL_HASH, executor);
        registry.deactivateAgent(agentId);
        vm.stopPrank();

        address targetBot = address(0xBAD);
        uint256 timestamp = block.timestamp;
        bytes memory signature = _signDetection(
            targetBot,
            timestamp,
            MODEL_HASH,
            executorPrivateKey
        );

        vm.expectRevert(ValidationRegistry.AgentNotActive.selector);
        registry.verifyDetection(agentId, targetBot, timestamp, signature);
    }

    // ============ EZKL Verification Tests ============

    function test_VerifyDetection_EZKLMode_ValidProof() public {
        vm.startPrank(nftHolder);
        registry.registerAgent(agentId, MODEL_HASH, executor);
        registry.updateToEZKL(agentId, address(zkVerifier));
        vm.stopPrank();

        zkVerifier.setShouldPass(true);

        address targetBot = address(0xBAD);
        uint256 timestamp = block.timestamp;
        bytes memory fakeProof = hex"1234";

        bool isValid = registry.verifyDetection(
            agentId,
            targetBot,
            timestamp,
            fakeProof
        );
        assertTrue(isValid);
    }

    function test_VerifyDetection_EZKLMode_InvalidProof() public {
        vm.startPrank(nftHolder);
        registry.registerAgent(agentId, MODEL_HASH, executor);
        registry.updateToEZKL(agentId, address(zkVerifier));
        vm.stopPrank();

        zkVerifier.setShouldPass(false);

        address targetBot = address(0xBAD);
        uint256 timestamp = block.timestamp;
        bytes memory fakeProof = hex"1234";

        bool isValid = registry.verifyDetection(
            agentId,
            targetBot,
            timestamp,
            fakeProof
        );
        assertFalse(isValid);
    }

    // ============ CheckDetection Tests ============

    function test_CheckDetection_ReturnsValidationResult() public {
        vm.prank(nftHolder);
        registry.registerAgent(agentId, MODEL_HASH, executor);

        address targetBot = address(0xBAD);
        uint256 timestamp = block.timestamp;
        bytes memory signature = _signDetection(
            targetBot,
            timestamp,
            MODEL_HASH,
            executorPrivateKey
        );

        (bool valid, string memory reason) = registry.checkDetection(
            agentId,
            targetBot,
            timestamp,
            signature
        );
        assertTrue(valid);
        assertEq(reason, "Valid");
    }

    function test_CheckDetection_NotRegistered() public {
        address targetBot = address(0xBAD);
        uint256 timestamp = block.timestamp;
        bytes memory signature = _signDetection(
            targetBot,
            timestamp,
            MODEL_HASH,
            executorPrivateKey
        );

        (bool valid, string memory reason) = registry.checkDetection(
            agentId,
            targetBot,
            timestamp,
            signature
        );
        assertFalse(valid);
        assertEq(reason, "Agent not registered");
    }

    // ============ View Function Tests ============

    function test_IsAgentActive() public {
        assertFalse(registry.isAgentActive(agentId)); // Not registered

        vm.prank(nftHolder);
        registry.registerAgent(agentId, MODEL_HASH, executor);
        assertTrue(registry.isAgentActive(agentId));

        vm.prank(nftHolder);
        registry.deactivateAgent(agentId);
        assertFalse(registry.isAgentActive(agentId));
    }

    function test_GetValidationMode() public {
        vm.startPrank(nftHolder);
        registry.registerAgent(agentId, MODEL_HASH, executor);

        assertTrue(
            registry.getValidationMode(agentId) ==
                ValidationRegistry.ValidationMode.SIGNATURE
        );

        registry.updateToEZKL(agentId, address(zkVerifier));
        assertTrue(
            registry.getValidationMode(agentId) ==
                ValidationRegistry.ValidationMode.EZKL_PROOF
        );

        vm.stopPrank();
    }

    // ============ Helper Functions ============

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
