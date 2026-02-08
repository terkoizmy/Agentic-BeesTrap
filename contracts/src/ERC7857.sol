// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC7857, IOracle} from "./interfaces/IERC7857.sol";

/**
 * @title ERC7857
 * @notice Base implementation of the ERC-7857 Intelligent NFT standard (0G Spec)
 */
abstract contract ERC7857 is ERC721, IERC7857, ReentrancyGuard {
    // ============ State Variables ============

    mapping(uint256 => bytes32) private _metadataHashes;
    mapping(uint256 => string) private _encryptedURIs;
    mapping(uint256 => mapping(address => bytes)) private _authorizations;

    address public oracle;

    // ============ Constructor ============

    constructor(
        string memory name_,
        string memory symbol_,
        address oracle_
    ) ERC721(name_, symbol_) {
        oracle = oracle_;
    }

    // ============ ERC-7857 Implementation ============

    /// @inheritdoc IERC7857
    function transfer(
        address from,
        address to,
        uint256 tokenId,
        bytes calldata sealedKey,
        bytes calldata proof
    ) external override nonReentrant {
        require(
            ownerOf(tokenId) == from,
            "ERC7857: transfer from incorrect owner"
        );
        // Allow spender to transfer on behalf of owner if approved
        if (msg.sender != from) {
            require(
                _isAuthorized(from, msg.sender, tokenId),
                "ERC7857: caller is not token owner or approved"
            );
        }

        require(IOracle(oracle).verifyProof(proof), "ERC7857: Invalid proof");

        // Update metadata access for new owner
        _updateMetadataAccess(tokenId, to, sealedKey, proof);

        // Transfer token ownership
        _transfer(from, to, tokenId);

        emit MetadataUpdated(tokenId, keccak256(sealedKey));
    }

    /// @inheritdoc IERC7857
    function clone(
        address to,
        uint256 tokenId,
        bytes calldata sealedKey,
        bytes calldata proof
    ) external override returns (uint256) {
        require(
            _isAuthorized(ownerOf(tokenId), msg.sender, tokenId) ||
                ownerOf(tokenId) == msg.sender,
            "ERC7857: caller is not owner or approved"
        );
        require(IOracle(oracle).verifyProof(proof), "ERC7857: Invalid proof");

        uint256 newTokenId = _mintClone(to);

        // Update metadata for the clone
        _updateMetadataAccess(newTokenId, to, sealedKey, proof);

        emit MetadataUpdated(newTokenId, keccak256(sealedKey));
        return newTokenId;
    }

    /// @inheritdoc IERC7857
    function authorizeUsage(
        uint256 tokenId,
        address executor,
        bytes calldata permissions
    ) external override {
        require(ownerOf(tokenId) == msg.sender, "ERC7857: caller is not owner");
        _authorizations[tokenId][executor] = permissions;
        emit UsageAuthorized(tokenId, executor);
    }

    // ============ Internal Logic ============

    function _updateMetadataAccess(
        uint256 tokenId,
        address /*newOwner*/,
        bytes calldata /*sealedKey*/,
        bytes calldata proof
    ) internal virtual {
        // Extract new metadata hash from proof (first 32 bytes convention from 0G docs)
        if (proof.length >= 32) {
            bytes32 newHash = bytes32(proof[0:32]);
            _metadataHashes[tokenId] = newHash;
        }

        // Update encrypted URI if provided in proof (after 64 bytes convention from 0G docs)
        if (proof.length > 64) {
            string memory newURI = string(proof[64:]);
            _encryptedURIs[tokenId] = newURI;
        }
    }

    /// @dev To be implemented by child for minting
    function _mintClone(address to) internal virtual returns (uint256);

    // ============ Getters ============

    function getMetadataHash(uint256 tokenId) external view returns (bytes32) {
        return _metadataHashes[tokenId];
    }

    function getEncryptedURI(
        uint256 tokenId
    ) external view returns (string memory) {
        return _encryptedURIs[tokenId];
    }

    // ============ Helper for Minting ============

    function _setEncryptedData(
        uint256 tokenId,
        string memory encryptedURI,
        bytes32 metadataHash
    ) internal {
        _encryptedURIs[tokenId] = encryptedURI;
        _metadataHashes[tokenId] = metadataHash;
    }

    // ============ Conflict Resolution ============

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC721, IERC165) returns (bool) {
        return
            interfaceId == type(IERC7857).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // Allow overriding name and symbol if needed
    function name()
        public
        view
        virtual
        override(ERC721)
        returns (string memory)
    {
        return super.name();
    }

    function symbol()
        public
        view
        virtual
        override(ERC721)
        returns (string memory)
    {
        return super.symbol();
    }
}
