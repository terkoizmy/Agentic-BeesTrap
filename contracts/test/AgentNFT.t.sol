// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {AgentNFT} from "../src/AgentNFT.sol";
import {IERC7857, IOracle} from "../src/interfaces/IERC7857.sol";

// Mock Oracle for testing
contract MockOracle is IOracle {
    bool public shouldVerify = true;

    function setVerify(bool _verify) external {
        shouldVerify = _verify;
    }

    function verifyProof(
        bytes calldata /*proof*/
    ) external view override returns (bool) {
        return shouldVerify;
    }
}

/**
 * @title AgentNFTTest
 * @notice Tests for the AgentNFT contract (0G Spec)
 */
contract AgentNFTTest is Test {
    AgentNFT public nft;
    MockOracle public oracle;

    address public owner = address(1);
    address public user1 = address(2);
    address public user2 = address(3);

    string public constant TEST_URI = "ipfs://QmTest123";
    string public constant TEST_ENCRYPTED_URI = "encrypted://QmSecret123";
    bytes32 public constant TEST_HASH = keccak256("metadata");

    function setUp() public {
        vm.startPrank(owner);
        oracle = new MockOracle();
        nft = new AgentNFT(owner, address(oracle));
        vm.stopPrank();
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsNameAndSymbol() public view {
        assertEq(nft.name(), "BeeTrap Agent");
        assertEq(nft.symbol(), "AGENT");
    }

    function test_Constructor_SetsOwner() public view {
        assertEq(nft.owner(), owner);
    }

    function test_Constructor_SetsOracle() public view {
        assertEq(nft.oracle(), address(oracle));
    }

    // ============ Mint Tests ============

    function test_Mint_Success() public {
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit AgentNFT.AgentMinted(0, user1, TEST_URI);

        uint256 tokenId = nft.mint(user1, TEST_URI);

        assertEq(tokenId, 0);
        assertEq(nft.ownerOf(0), user1);
        assertEq(nft.tokenURI(0), TEST_URI);
        vm.stopPrank();
    }

    function test_MintIntelligent_Success() public {
        vm.startPrank(owner);
        uint256 tokenId = nft.mintIntelligent(
            user1,
            TEST_ENCRYPTED_URI,
            TEST_HASH
        );

        assertEq(nft.ownerOf(tokenId), user1);
        assertEq(nft.getEncryptedURI(tokenId), TEST_ENCRYPTED_URI);
        assertEq(nft.getMetadataHash(tokenId), TEST_HASH);
        vm.stopPrank();
    }

    // ============ ERC-7857 Tests ============

    function test_Transfer_WithProof() public {
        vm.prank(owner);
        nft.mint(user1, TEST_URI);

        bytes memory sealedKey = hex"1234";
        bytes memory proof = hex"5678";

        vm.prank(user1);
        nft.transfer(user1, user2, 0, sealedKey, proof);

        assertEq(nft.ownerOf(0), user2);
    }

    function test_Clone_WithProof() public {
        vm.prank(owner);
        nft.mint(user1, TEST_URI);

        bytes memory sealedKey = hex"1234";
        bytes memory proof = hex"5678";

        vm.prank(user1);
        uint256 newTokenId = nft.clone(user2, 0, sealedKey, proof);

        assertEq(nft.ownerOf(newTokenId), user2);
        assertEq(newTokenId, 1);
    }

    function test_AuthorizeUsage() public {
        vm.prank(owner);
        nft.mint(user1, TEST_URI);

        bytes memory permissions = hex"ABCD";

        vm.expectEmit(true, true, false, true);
        emit IERC7857.UsageAuthorized(0, user2);

        vm.prank(user1);
        nft.authorizeUsage(0, user2, permissions);
    }

    function test_AuthorizeUsage_RevertNotOwner() public {
        vm.prank(owner);
        nft.mint(user1, TEST_URI);

        bytes memory permissions = hex"ABCD";

        vm.prank(user2);
        vm.expectRevert("ERC7857: caller is not owner");
        nft.authorizeUsage(0, user2, permissions);
    }

    // ============ Oracle Verification Failure Tests ============

    function test_Transfer_RevertInvalidProof() public {
        vm.prank(owner);
        nft.mint(user1, TEST_URI);

        oracle.setVerify(false);

        bytes memory sealedKey = hex"1234";
        bytes memory proof = hex"5678";

        vm.prank(user1);
        vm.expectRevert("ERC7857: Invalid proof");
        nft.transfer(user1, user2, 0, sealedKey, proof);
    }
}
