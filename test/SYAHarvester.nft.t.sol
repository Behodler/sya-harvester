// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {HarvesterFixture} from "./utils/HarvesterFixture.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockSYA} from "./mocks/MockSYA.sol";

/// @notice Claim-NFT pull before the unlock and full-balance refund after it.
/// @dev Uses the mock SYA in two modes: `Burn` (live behaviour, SYA burns one unit from the harvester as
///      an authorized burner) and `Ignore` (post-gating-off, SYA leaves the NFT untouched).
contract SYAHarvesterNftTest is HarvesterFixture {
    MockERC1155 internal nft;

    uint256 internal constant NFT_INDEX = 3;

    function setUp() public override {
        super.setUp();
        nft = new MockERC1155();
        nft.setAuthorizedBurner(address(sya), true);
        sya.setNFTMinter(address(nft));

        nft.mint(keeper, NFT_INDEX, 2);
        vm.prank(keeper);
        nft.setApprovalForAll(address(harvester), true);
    }

    /// @dev Prefix of `safeTransferFrom(harvester, ...)`: any transfer out of the harvester (the refund)
    function _refundCallPrefix() internal view returns (bytes memory) {
        return abi.encodeWithSelector(IERC1155.safeTransferFrom.selector, address(harvester));
    }

    /*//////////////////////////////////////////////////////////////
                         LIVE: SYA BURNS THE UNIT
    //////////////////////////////////////////////////////////////*/

    function test_nft_pulledThenBurned_noRefund() public {
        sya.setNftMode(MockSYA.NftMode.Burn);
        uint256 before = nft.balanceOf(keeper, NFT_INDEX);

        vm.expectCall(
            address(nft), abi.encodeCall(IERC1155.safeTransferFrom, (keeper, address(harvester), NFT_INDEX, 1, "")), 1
        );
        vm.expectCall(address(nft), _refundCallPrefix(), 0);

        vm.prank(keeper);
        uint256 ethOut = harvester.harvest(_none(), NFT_INDEX, 0);

        assertGt(ethOut, 0, "ethOut");
        assertEq(nft.balanceOf(keeper, NFT_INDEX), before - 1, "caller lost exactly one unit");
        assertEq(nft.balanceOf(address(harvester), NFT_INDEX), 0, "harvester holds none");
        assertEq(nft.totalSupply(NFT_INDEX), before - 1, "unit burned, not parked");
        _assertHarvesterEmpty();
    }

    /*//////////////////////////////////////////////////////////////
                    POST GATING-OFF: SYA IGNORES THE NFT
    //////////////////////////////////////////////////////////////*/

    function test_nft_ignoredBySya_heldDuringUnlock_thenRefunded() public {
        // Mode Ignore is the default
        uint256 before = nft.balanceOf(keeper, NFT_INDEX);

        vm.prank(keeper);
        harvester.harvest(_none(), NFT_INDEX, 0);

        assertEq(sya.nftBalanceSeenInClaim(), 1, "harvester held the pulled unit during claim");
        assertEq(nft.balanceOf(keeper, NFT_INDEX), before, "caller balance unchanged");
        assertEq(nft.balanceOf(address(harvester), NFT_INDEX), 0, "harvester holds none");
    }

    function test_nft_refundReturnsWholeBalance_includingStrayUnits() public {
        // A stray unit sent to the harvester earlier is swept back to the caller along with the pulled one
        nft.mint(address(harvester), NFT_INDEX, 1);
        uint256 before = nft.balanceOf(keeper, NFT_INDEX);

        vm.expectCall(
            address(nft), abi.encodeCall(IERC1155.safeTransferFrom, (address(harvester), keeper, NFT_INDEX, 2, "")), 1
        );

        vm.prank(keeper);
        harvester.harvest(_none(), NFT_INDEX, 0);

        assertEq(sya.nftBalanceSeenInClaim(), 2, "pulled unit plus stray unit held during claim");
        assertEq(nft.balanceOf(keeper, NFT_INDEX), before + 1, "caller receives the whole balance");
        assertEq(nft.balanceOf(address(harvester), NFT_INDEX), 0, "harvester holds none");
    }

    /*//////////////////////////////////////////////////////////////
                                SKIP PATHS
    //////////////////////////////////////////////////////////////*/

    function test_nft_indexZero_noErc1155Calls() public {
        // Zero calls of any kind to the NFT contract (so no balance reads after the harvest either: they
        // would be counted; no call at all already implies no balance moved)
        vm.expectCall(address(nft), "", 0);

        vm.prank(keeper);
        uint256 ethOut = harvester.harvest(_none(), 0, 0);

        assertGt(ethOut, 0, "ethOut");
    }

    function test_nft_noMinterConfigured_skipsBothTransfers() public {
        sya.setNFTMinter(address(0));

        // Zero calls of any kind to the NFT contract: neither the pull nor the refund (nor its balance read)
        vm.expectCall(address(nft), "", 0);

        vm.prank(keeper);
        uint256 ethOut = harvester.harvest(_none(), NFT_INDEX, 0);

        assertGt(ethOut, 0, "ethOut");
    }

    /*//////////////////////////////////////////////////////////////
                                APPROVALS
    //////////////////////////////////////////////////////////////*/

    function test_nft_callerWithoutApproval_revertsOnPull() public {
        vm.prank(keeper);
        nft.setApprovalForAll(address(harvester), false);

        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155MissingApprovalForAll.selector, address(harvester), keeper)
        );
        vm.prank(keeper);
        harvester.harvest(_none(), NFT_INDEX, 0);
    }

    function test_nft_burnNeedsNoApprovalFromHarvester() public {
        // SYA burns as an authorized burner: the harvester grants nothing to SYA
        sya.setNftMode(MockSYA.NftMode.Burn);
        assertFalse(nft.isApprovedForAll(address(harvester), address(sya)), "no harvester approval");

        vm.prank(keeper);
        harvester.harvest(_none(), NFT_INDEX, 0);

        assertEq(nft.balanceOf(keeper, NFT_INDEX), 1, "burned one unit");
    }

    /*//////////////////////////////////////////////////////////////
                               INTERFACES
    //////////////////////////////////////////////////////////////*/

    function test_supportsInterface_erc1155Receiver() public view {
        IERC165 h = IERC165(address(harvester));
        assertTrue(h.supportsInterface(type(IERC1155Receiver).interfaceId), "IERC1155Receiver");
        assertTrue(h.supportsInterface(type(IERC165).interfaceId), "IERC165");
    }
}
