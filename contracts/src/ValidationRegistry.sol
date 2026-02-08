// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title IZKVerifier
 * @notice Interface for EZKL-generated ZK verifier contracts
 * @dev This interface will be implemented by the EZKL-generated verifier contract.
 *      When you compile your ONNX model with EZKL, it generates a Solidity verifier
 *      that implements this interface.
 *
 * Integration Steps for EZKL:
 * 1. Export your ONNX model: `ezkl gen-settings -M model.onnx`
 * 2. Generate verifier: `ezkl create-evm-verifier`
 * 3. Deploy the generated verifier contract
 * 4. Call updateToEZKL() with the verifier address
 */
interface IZKVerifier {
    /**
     * @notice Verify a ZK-ML proof
     * @param proof The serialized proof bytes from EZKL
     * @param publicInputs The public inputs to the circuit (e.g., model output hash)
     * @return True if the proof is valid
     */
    function verify(
        bytes calldata proof,
        bytes32[] calldata publicInputs
    ) external view returns (bool);
}

/**
 * @title ValidationRegistry
 * @author BeeTrap Agentic Security Team
 * @notice Registry for AI agent validation with support for ECDSA signatures and ZK-ML proofs
 * @dev This contract serves as the source of truth for agent parameters and validates detection signals.
 *      It is designed to be "future-proof" with a clean upgrade path from ECDSA to EZKL.
 *
 * Architecture:
 * - Each agent (represented by an AgentNFT) has a configuration stored in this registry
 * - The configuration includes the model hash, executor address, and validation mode
 * - Initially, agents use SIGNATURE mode (fast, gas-efficient)
 * - Later, agents can upgrade to EZKL_PROOF mode (trustless, verifiable)
 */
contract ValidationRegistry {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ============ Enums ============

    /// @notice Validation mode determines how detection signals are verified
    /// @dev SIGNATURE: Uses ECDSA signatures from the executor (fast, requires trust)
    ///      EZKL_PROOF: Uses ZK-ML proofs for trustless verification (slower, trustless)
    enum ValidationMode {
        SIGNATURE,
        EZKL_PROOF
    }

    // ============ Structs ============

    /// @notice Configuration for a registered AI agent
    /// @param modelHash SHA-256 hash of the ONNX model file (commitment to model identity)
    /// @param executor The wallet address of the Rust agent that signs detections
    /// @param zkVerifier Address of the EZKL-generated verifier contract (future use)
    /// @param mode Current validation mode (SIGNATURE or EZKL_PROOF)
    /// @param isActive Whether the agent is currently active
    struct AgentConfig {
        bytes32 modelHash;
        address executor;
        address zkVerifier;
        ValidationMode mode;
        bool isActive;
    }

    // ============ State Variables ============

    /// @notice The AgentNFT contract for verifying ownership
    IERC721 public immutable AGENT_NFT;

    /// @notice Mapping from NFT token ID to agent configuration
    mapping(uint256 => AgentConfig) public registry;

    /// @notice Maximum age for a detection timestamp (prevents replay attacks)
    uint256 public constant MAX_DETECTION_AGE = 5 minutes;

    // ============ Events ============

    /// @notice Emitted when an agent is registered or updated
    event AgentRegistered(
        uint256 indexed nftId,
        bytes32 modelHash,
        address executor,
        ValidationMode mode
    );

    /// @notice Emitted when an agent upgrades to EZKL mode
    event AgentUpgradedToEZKL(uint256 indexed nftId, address zkVerifier);

    /// @notice Emitted when an agent is deactivated
    event AgentDeactivated(uint256 indexed nftId);

    /// @notice Emitted when an agent is reactivated
    event AgentActivated(uint256 indexed nftId);

    /// @notice Emitted when a detection is successfully verified
    event DetectionVerified(
        uint256 indexed nftId,
        address indexed targetBot,
        uint256 timestamp,
        ValidationMode mode
    );

    // ============ Errors ============

    /// @notice Thrown when caller is not the NFT owner
    error NotNFTOwner();

    /// @notice Thrown when agent is not registered
    error AgentNotRegistered();

    /// @notice Thrown when agent is not active
    error AgentNotActive();

    /// @notice Thrown when detection timestamp is too old
    error DetectionExpired();

    /// @notice Thrown when signature verification fails
    error InvalidSignature();

    /// @notice Thrown when ZK proof verification fails
    error InvalidProof();

    /// @notice Thrown when trying to set an invalid verifier address
    error InvalidVerifierAddress();

    /// @notice Thrown when agent is already in EZKL mode
    error AlreadyInEZKLMode();

    // ============ Modifiers ============

    /// @notice Ensures caller owns the specified NFT
    modifier onlyNFTOwner(uint256 nftId) {
        if (AGENT_NFT.ownerOf(nftId) != msg.sender) revert NotNFTOwner();
        _;
    }

    /// @notice Ensures agent is registered and active
    modifier onlyActiveAgent(uint256 nftId) {
        if (registry[nftId].executor == address(0)) revert AgentNotRegistered();
        if (!registry[nftId].isActive) revert AgentNotActive();
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Initialize the ValidationRegistry
     * @param agentNFT The address of the AgentNFT contract
     */
    constructor(address agentNFT) {
        AGENT_NFT = IERC721(agentNFT);
    }

    // ============ Registration Functions ============

    /**
     * @notice Register a new agent or update existing configuration
     * @dev Only the NFT owner can register/update the agent configuration
     * @param nftId The token ID of the AgentNFT
     * @param modelHash SHA-256 hash of the ONNX model (use: sha256sum beetrap_model.onnx)
     * @param executor The wallet address that will sign detection messages
     */
    function registerAgent(
        uint256 nftId,
        bytes32 modelHash,
        address executor
    ) external onlyNFTOwner(nftId) {
        registry[nftId] = AgentConfig({
            modelHash: modelHash,
            executor: executor,
            zkVerifier: address(0),
            mode: ValidationMode.SIGNATURE,
            isActive: true
        });

        emit AgentRegistered(
            nftId,
            modelHash,
            executor,
            ValidationMode.SIGNATURE
        );
    }

    /**
     * @notice Upgrade an agent from SIGNATURE mode to EZKL_PROOF mode
     * @dev This is a one-way upgrade. Once in EZKL mode, the agent uses ZK proofs.
     * @param nftId The token ID of the AgentNFT
     * @param _zkVerifier Address of the deployed EZKL verifier contract
     *
     * Integration with EZKL:
     * 1. Compile your ONNX model with EZKL to generate a Solidity verifier
     * 2. Deploy the verifier contract
     * 3. Call this function with the verifier address
     *
     * Example EZKL commands:
     *   ezkl gen-settings -M beetrap_model.onnx -O settings.json
     *   ezkl compile-circuit -M beetrap_model.onnx -S settings.json -O circuit.ezkl
     *   ezkl create-evm-verifier -S settings.json -C circuit.ezkl -O Verifier.sol
     */
    function updateToEZKL(
        uint256 nftId,
        address _zkVerifier
    ) external onlyNFTOwner(nftId) {
        if (_zkVerifier == address(0)) revert InvalidVerifierAddress();
        if (registry[nftId].mode == ValidationMode.EZKL_PROOF)
            revert AlreadyInEZKLMode();
        if (registry[nftId].executor == address(0)) revert AgentNotRegistered();

        registry[nftId].zkVerifier = _zkVerifier;
        registry[nftId].mode = ValidationMode.EZKL_PROOF;

        emit AgentUpgradedToEZKL(nftId, _zkVerifier);
    }

    /**
     * @notice Deactivate an agent (pauses validation)
     * @param nftId The token ID of the AgentNFT
     */
    function deactivateAgent(uint256 nftId) external onlyNFTOwner(nftId) {
        registry[nftId].isActive = false;
        emit AgentDeactivated(nftId);
    }

    /**
     * @notice Reactivate a previously deactivated agent
     * @param nftId The token ID of the AgentNFT
     */
    function activateAgent(uint256 nftId) external onlyNFTOwner(nftId) {
        registry[nftId].isActive = true;
        emit AgentActivated(nftId);
    }

    // ============ Verification Functions ============

    /**
     * @notice Verify a detection signal from an AI agent
     * @dev This function is designed to be called by BeeTrapHook to validate detections
     * @param nftId The token ID of the AgentNFT that made the detection
     * @param targetBot The address detected as a predator bot
     * @param timestamp The timestamp when the detection was made
     * @param proofOrSignature Either an ECDSA signature or a ZK proof, depending on mode
     * @return valid True if the detection is verified
     *
     * For SIGNATURE mode:
     *   The proofOrSignature should be an ECDSA signature (65 bytes)
     *   Message format: keccak256(abi.encodePacked(targetBot, timestamp, modelHash))
     *
     * For EZKL_PROOF mode:
     *   The proofOrSignature should be the serialized ZK proof from EZKL
     *   Public inputs: [targetBotHash, timestampHash, modelHash]
     */
    function verifyDetection(
        uint256 nftId,
        address targetBot,
        uint256 timestamp,
        bytes memory proofOrSignature
    ) external view onlyActiveAgent(nftId) returns (bool valid) {
        // Check timestamp freshness to prevent replay attacks
        if (block.timestamp > timestamp + MAX_DETECTION_AGE) {
            revert DetectionExpired();
        }

        AgentConfig storage config = registry[nftId];

        if (config.mode == ValidationMode.SIGNATURE) {
            return
                _verifySignature(
                    config,
                    targetBot,
                    timestamp,
                    proofOrSignature
                );
        } else {
            return
                _verifyZKProof(config, targetBot, timestamp, proofOrSignature);
        }
    }

    /**
     * @notice Check if a detection would be valid (dry-run without revert)
     * @dev Useful for off-chain validation before submitting a transaction
     * @param nftId The token ID of the AgentNFT
     * @param targetBot The address detected as a predator bot
     * @param timestamp The timestamp when the detection was made
     * @param proofOrSignature The signature or proof
     * @return valid True if valid, false otherwise (no revert)
     * @return reason Human-readable reason if invalid
     */
    function checkDetection(
        uint256 nftId,
        address targetBot,
        uint256 timestamp,
        bytes memory proofOrSignature
    ) external view returns (bool valid, string memory reason) {
        AgentConfig storage config = registry[nftId];

        if (config.executor == address(0)) {
            return (false, "Agent not registered");
        }
        if (!config.isActive) {
            return (false, "Agent not active");
        }
        if (block.timestamp > timestamp + MAX_DETECTION_AGE) {
            return (false, "Detection expired");
        }

        if (config.mode == ValidationMode.SIGNATURE) {
            bool sigValid = _verifySignature(
                config,
                targetBot,
                timestamp,
                proofOrSignature
            );
            if (!sigValid) {
                return (false, "Invalid signature");
            }
        } else {
            bool proofValid = _verifyZKProof(
                config,
                targetBot,
                timestamp,
                proofOrSignature
            );
            if (!proofValid) {
                return (false, "Invalid ZK proof");
            }
        }

        return (true, "Valid");
    }

    // ============ View Functions ============

    /**
     * @notice Get the full configuration for an agent
     * @param nftId The token ID of the AgentNFT
     * @return config The agent configuration struct
     */
    function getAgentConfig(
        uint256 nftId
    ) external view returns (AgentConfig memory) {
        return registry[nftId];
    }

    /**
     * @notice Check if an agent is registered and active
     * @param nftId The token ID of the AgentNFT
     * @return True if registered and active
     */
    function isAgentActive(uint256 nftId) external view returns (bool) {
        return
            registry[nftId].executor != address(0) && registry[nftId].isActive;
    }

    /**
     * @notice Get the current validation mode for an agent
     * @param nftId The token ID of the AgentNFT
     * @return The validation mode (SIGNATURE or EZKL_PROOF)
     */
    function getValidationMode(
        uint256 nftId
    ) external view returns (ValidationMode) {
        return registry[nftId].mode;
    }

    // ============ Internal Functions ============

    /**
     * @notice Verify an ECDSA signature for SIGNATURE mode
     * @dev The message hash includes targetBot, timestamp, and modelHash to bind the detection
     * @param config The agent configuration
     * @param targetBot The detected predator address
     * @param timestamp The detection timestamp
     * @param signature The ECDSA signature (65 bytes: r, s, v)
     * @return True if the signature is valid and from the registered executor
     */
    function _verifySignature(
        AgentConfig storage config,
        address targetBot,
        uint256 timestamp,
        bytes memory signature
    ) internal view returns (bool) {
        // Construct the message hash
        // This binds the detection to: target, time, and specific model
        bytes32 messageHash = keccak256(
            abi.encodePacked(targetBot, timestamp, config.modelHash)
        );

        // Convert to Ethereum signed message hash (EIP-191)
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();

        // Recover the signer
        address signer = ethSignedHash.recover(signature);

        // Verify the signer is the registered executor
        return signer == config.executor;
    }

    /**
     * @notice Verify a ZK proof for EZKL_PROOF mode
     * @dev This calls the external EZKL verifier contract
     * @param config The agent configuration
     * @param targetBot The detected predator address
     * @param timestamp The detection timestamp
     * @param proof The serialized ZK proof from EZKL
     * @return True if the proof is valid
     *
     * Public Inputs Structure (to be matched with EZKL circuit):
     * - publicInputs[0]: Hash of targetBot address
     * - publicInputs[1]: Hash of timestamp
     * - publicInputs[2]: modelHash (from config, ensures proof is for correct model)
     *
     * Note: The exact public input format depends on how you configure your EZKL circuit.
     * Modify this function to match your circuit's public input structure.
     */
    function _verifyZKProof(
        AgentConfig storage config,
        address targetBot,
        uint256 timestamp,
        bytes memory proof
    ) internal view returns (bool) {
        // Construct public inputs for the ZK verifier
        bytes32[] memory publicInputs = new bytes32[](3);
        publicInputs[0] = keccak256(abi.encodePacked(targetBot));
        publicInputs[1] = keccak256(abi.encodePacked(timestamp));
        publicInputs[2] = config.modelHash;

        // Call the external ZK verifier
        // This will revert if the verifier is not set or proof is invalid
        try IZKVerifier(config.zkVerifier).verify(proof, publicInputs) returns (
            bool result
        ) {
            return result;
        } catch {
            return false;
        }
    }
}
