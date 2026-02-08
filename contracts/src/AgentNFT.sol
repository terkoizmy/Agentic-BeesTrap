// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC7857} from "./ERC7857.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AgentNFT
 * @notice Implementation of the 0G AI Agent NFT standard
 * @dev Each token represents a unique AI agent identity with metadata stored via tokenURI.
 *      The tokenURI should point to a JSON file containing agent registration data as per ERC-8004.
 */
contract AgentNFT is ERC7857, ERC721URIStorage, Ownable {
    // ============ State Variables ============

    /// @notice Counter for auto-incrementing token IDs
    uint256 private _nextTokenId;

    // ============ Events ============

    /// @notice Emitted when a new agent identity is minted
    /// @param tokenId The unique identifier of the minted agent NFT
    /// @param to The address that received the agent NFT
    /// @param uri The metadata URI for the agent
    event AgentMinted(uint256 indexed tokenId, address indexed to, string uri);

    // ============ Constructor ============

    /**
     * @notice Initializes the AgentNFT contract
     * @param initialOwner The address that will own the contract and can mint new agents
     * @param oracle The address of the data oracle contract
     */
    constructor(
        address initialOwner,
        address oracle
    ) ERC7857("BeeTrap Agent", "AGENT", oracle) Ownable(initialOwner) {}

    // ============ External Functions ============

    /**
     * @notice Mint a new agent identity NFT with standard URI
     * @dev Only the contract owner can mint new agents
     * @param to The address that will receive the agent NFT
     * @param uri The metadata URI (IPFS, HTTPS, or data: URI)
     * @return tokenId The unique identifier of the newly minted agent
     */
    function mint(
        address to,
        string memory uri
    ) external onlyOwner returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);

        emit AgentMinted(tokenId, to, uri);

        return tokenId;
    }

    /**
     * @notice Mint a new agent identity NFT with encrypted 0G metadata
     * @dev Only the contract owner can mint new agents
     * @param to The address that will receive the agent NFT
     * @param encryptedURI The encrypted URI string
     * @param metadataHash The hash of the encrypted metadata
     * @return tokenId The unique identifier of the newly minted agent
     */
    function mintIntelligent(
        address to,
        string memory encryptedURI,
        bytes32 metadataHash
    ) external onlyOwner returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        _setEncryptedData(tokenId, encryptedURI, metadataHash);

        emit AgentMinted(tokenId, to, "encrypted");

        return tokenId;
    }

    /**
     * @notice Get the total number of agents minted
     * @return The total supply of agent NFTs
     */
    function totalSupply() external view returns (uint256) {
        return _nextTokenId;
    }

    // ============ Internal Functions ============

    /// @inheritdoc ERC7857
    function _mintClone(address to) internal override returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        return tokenId;
    }

    // ============ Override Functions ============

    /**
     * @notice Returns the token name
     * @dev Overrides ERC7857 and ERC721
     */
    function name()
        public
        view
        override(ERC7857, ERC721)
        returns (string memory)
    {
        return super.name();
    }

    /**
     * @notice Returns the token symbol
     * @dev Overrides ERC7857 and ERC721
     */
    function symbol()
        public
        view
        override(ERC7857, ERC721)
        returns (string memory)
    {
        return super.symbol();
    }

    /**
     * @notice Returns the token URI for a given token ID
     * @dev Overrides both ERC721 and ERC721URIStorage
     * @param tokenId The ID of the token to query
     * @return The URI string for the token metadata
     */
    function tokenURI(
        uint256 tokenId
    ) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    /**
     * @notice Check if the contract supports a given interface
     * @dev Overrides both ERC7857 (which overrides ERC721) and ERC721URIStorage
     * @param interfaceId The interface identifier to check
     * @return True if the interface is supported
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC7857, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // ============ BeeTrap Integration ============

    /// @notice The BeeTrapHook contract address
    address public beeTrapHook;

    /// @notice Mapping of authorized agent token IDs
    mapping(uint256 => bool) public isAuthorized;

    /// @notice Emitted when BeeTrapHook address is set
    event BeeTrapHookSet(address indexed hook);

    /// @notice Emitted when an agent is authorized
    event AgentAuthorized(uint256 indexed tokenId);

    /**
     * @notice Set the BeeTrapHook contract address
     * @param _hook The address of the BeeTrapHook
     */
    function setBeeTrapHook(address _hook) external onlyOwner {
        beeTrapHook = _hook;
        emit BeeTrapHookSet(_hook);
    }

    /**
     * @notice Authorize a specific agent token ID to perform actions
     * @param tokenId The token ID to authorize
     */
    function authorizeAgent(uint256 tokenId) external onlyOwner {
        isAuthorized[tokenId] = true;
        emit AgentAuthorized(tokenId);
    }

    /**
     * @notice Proxy function to mark a predator in the BeeTrapHook
     * @dev Only allows owners of authorized tokens to call
     * @param tokenId The agent token ID providing authorization
     * @param bot The address to mark
     * @param status The status to set
     * @param proof The ZK proof bytes
     * @param publicInputs The public inputs
     */
    function markAsPredatorWithProof(
        uint256 tokenId,
        address bot,
        bool status,
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external {
        // Check ownership
        if (ownerOf(tokenId) != msg.sender) revert("Not token owner");
        // Check authorization
        if (!isAuthorized[tokenId]) revert("Agent not authorized");
        // Check hook set
        if (beeTrapHook == address(0)) revert("Hook not set");

        // Call hook
        // We use low-level call or interface. Need interface.
        // Assuming BeeTrapHook interface matches what we implemented.
        IBeeTrapHook(beeTrapHook).markAsPredatorWithProof(
            bot,
            status,
            proof,
            publicInputs
        );
    }
}

interface IBeeTrapHook {
    function markAsPredatorWithProof(
        address bot,
        bool status,
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external;
}
