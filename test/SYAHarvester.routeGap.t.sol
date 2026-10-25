// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SYAHarvester} from "../src/SYAHarvester.sol";
import {HarvesterFixture} from "./utils/HarvesterFixture.sol";

/// @notice Audit 01, M-01 at harvest level, with the Router NG–faithful `MockCurveRouter`.
/// @dev Failure mode: a gapped route `[USDe, pool, crvUSD, 0, ..., 0, USDC]` executes only its first hop, so
///      Router NG delivers crvUSD; when other legs cover the flash borrow the harvest succeeds and the crvUSD is
///      stranded (the contract has no sweep). The fix makes such a route unstorable.
contract SYAHarvesterRouteGapTest is HarvesterFixture {
    MockERC20 internal crvusd;

    function setUp() public override {
        super.setUp();
        crvusd = new MockERC20("crvUSD", "crvUSD", 18);
        // The faithful mock would pay crvUSD for a gapped route, so make that payout possible
        crvusd.mint(address(router), 1e30);
    }

    function _gapPath() internal view returns (address[11] memory p) {
        p[0] = address(usde);
        p[1] = curvePool;
        p[2] = address(crvusd);
        p[10] = address(usdc);
    }

    function test_routeGap_gappedRouteCannotBeStored() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteGap(uint256)", 10));
        harvester.setRoute(address(usde), _gapPath(), _params(), _pools());

        // the fixture's contiguous route is untouched
        SYAHarvester.CurveRoute memory r = harvester.getRoute(address(usde));
        assertEq(r.path[2], address(usdc));
        assertEq(r.path[10], address(0));
    }

    function test_routeGap_mockDeliversIntermediateForGappedPath() public {
        // What the stored gapped route would have done inside harvest: the router pays crvUSD, not USDC
        usde.mint(address(this), 100e18);
        usde.approve(address(router), 100e18);
        router.exchange(_gapPath(), _params(), 100e18, 0, _pools(), address(this));
        assertGt(crvusd.balanceOf(address(this)), 0, "intermediate delivered");
        assertEq(usdc.balanceOf(address(this)), 0, "reward token not delivered");
    }

    function test_routeGap_contiguousFixtureRoute_harvestLeavesNoBalances() public {
        // A second strategy covers the borrow on its own, which is the precondition that let M-01 succeed silently
        _addStrategy(dola, DOLA_YIELD);
        vm.prank(owner);
        harvester.setRoute(address(dola), _path(address(dola)), _params(), _pools());

        vm.prank(keeper);
        uint256 ethOut = harvester.harvest(_none(), 1, 0);

        assertGt(ethOut, 0, "ethOut");
        assertEq(router.calls(address(usde)), 1);
        assertEq(router.calls(address(dola)), 1);
        assertEq(crvusd.balanceOf(address(harvester)), 0, "harvester crvUSD");
        _assertHarvesterEmpty();
    }
}
