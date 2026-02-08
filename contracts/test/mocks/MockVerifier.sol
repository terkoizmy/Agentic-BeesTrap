// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title MockVerifier
 * @notice A simple mock verifier for testing ZK proof verification logic
 * @dev This mock allows tests to control whether verification succeeds or fails
 */
contract MockVerifier {
    bool public shouldVerify;
    uint256 public verifyCallCount;
    
    // Store last verification attempt for debugging
    uint256[] public lastProof;
    uint256[] public lastPublicInputs;
    
    event VerificationAttempted(bool result, uint256 proofLength, uint256 inputsLength);
    
    constructor(bool _shouldVerify) {
        shouldVerify = _shouldVerify;
    }
    
    /**
     * @notice Mock verify function matching Halo2Verifier interface
     * @dev Returns the pre-configured shouldVerify value
     */
    function verify(
        uint256[] calldata proof,
        uint256[] calldata publicInputs
    ) external returns (bool) {
        verifyCallCount++;
        
        // Store for inspection
        delete lastProof;
        delete lastPublicInputs;
        
        for (uint256 i = 0; i < proof.length; i++) {
            lastProof.push(proof[i]);
        }
        
        for (uint256 i = 0; i < publicInputs.length; i++) {
            lastPublicInputs.push(publicInputs[i]);
        }
        
        emit VerificationAttempted(shouldVerify, proof.length, publicInputs.length);
        
        return shouldVerify;
    }
    
    /**
     * @notice Change the verification result for future calls
     */
    function setShouldVerify(bool _shouldVerify) external {
        shouldVerify = _shouldVerify;
    }
    
    /**
     * @notice Reset the call counter
     */
    function resetCallCount() external {
        verifyCallCount = 0;
    }
    
    /**
     * @notice Get the last proof submitted
     */
    function getLastProof() external view returns (uint256[] memory) {
        return lastProof;
    }
    
    /**
     * @notice Get the last public inputs submitted
     */
    function getLastPublicInputs() external view returns (uint256[] memory) {
        return lastPublicInputs;
    }
}

/**
 * @title MockHalo2Verifier
 * @notice A more realistic mock that simulates EZKL's Halo2 verifier behavior
 * @dev This mock validates proof structure and input format
 */
contract MockHalo2Verifier {
    // Expected proof structure from EZKL
    uint256 public constant EXPECTED_PROOF_LENGTH = 8;
    uint256 public constant EXPECTED_PUBLIC_INPUTS_LENGTH = 1;
    
    bool public strictMode; // If true, validates proof structure
    mapping(bytes32 => bool) public validProofs; // Pre-registered valid proofs
    
    uint256 public verifyCallCount;
    
    event ProofVerified(bytes32 indexed proofHash, bool valid);
    event InvalidProofStructure(string reason);
    
    constructor(bool _strictMode) {
        strictMode = _strictMode;
    }
    
    /**
     * @notice Verify a ZK proof
     * @dev In strict mode, validates proof structure. Otherwise checks pre-registered proofs.
     */
    function verify(
        uint256[] calldata proof,
        uint256[] calldata publicInputs
    ) external returns (bool) {
        verifyCallCount++;
        
        // Strict mode: validate structure
        if (strictMode) {
            if (proof.length != EXPECTED_PROOF_LENGTH) {
                emit InvalidProofStructure("Invalid proof length");
                return false;
            }
            
            if (publicInputs.length != EXPECTED_PUBLIC_INPUTS_LENGTH) {
                emit InvalidProofStructure("Invalid public inputs length");
                return false;
            }
            
            // Check that proof elements are non-zero (basic sanity check)
            for (uint256 i = 0; i < proof.length; i++) {
                if (proof[i] == 0) {
                    emit InvalidProofStructure("Proof contains zero elements");
                    return false;
                }
            }
        }
        
        // Check if proof is pre-registered as valid
        bytes32 proofHash = keccak256(abi.encodePacked(proof, publicInputs));
        bool isValid = validProofs[proofHash];
        
        emit ProofVerified(proofHash, isValid);
        
        return isValid;
    }
    
    /**
     * @notice Register a proof as valid for testing
     */
    function registerValidProof(
        uint256[] calldata proof,
        uint256[] calldata publicInputs
    ) external {
        bytes32 proofHash = keccak256(abi.encodePacked(proof, publicInputs));
        validProofs[proofHash] = true;
    }
    
    /**
     * @notice Unregister a proof
     */
    function revokeProof(
        uint256[] calldata proof,
        uint256[] calldata publicInputs
    ) external {
        bytes32 proofHash = keccak256(abi.encodePacked(proof, publicInputs));
        validProofs[proofHash] = false;
    }
    
    /**
     * @notice Toggle strict mode
     */
    function setStrictMode(bool _strictMode) external {
        strictMode = _strictMode;
    }
}
