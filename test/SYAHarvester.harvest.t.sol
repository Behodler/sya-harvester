// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdError} from "forge-std/StdError.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IStableYieldAccumulator} from "stable-yield-accumulator/src/interfaces/IStableYieldAccumulator.sol";

import {SYAHarvester} from "../src/SYAHarvester.sol";
import {ICurveRouterNG} from "../src/interfaces/ICurveRouterNG.sol";
import {HarvesterFixture} from "./utils/HarvesterFixture.sol";

/// @notice Harvest flow against a real local Uniswap V4 PoolManager with mock SYA, strategies and router.
/// @dev Harness lives in `HarvesterFixture`. The mock SYA defaults to NFT `Ignore` mode with no minter,
///      so `nftIndex` is not transferred here; NFT behaviour is covered by `SYAHarvester.nft.t.sol`.
contract SYAHarvesterHarvestTest is HarvesterFixture {
    /*//////////////////////////////////////////////////////////////
                              PROFITABLE PATH
    //////////////////////////////////////////////////////////////*/

    function test_harvest_profitablePath_paysEthToCaller() public {
        uint256 before = keeper.balance;

        vm.prank(keeper);
        uint256 ethOut = harvester.harvest(_none(), 1, 0);

        assertGt(ethOut, 0, "ethOut");
        assertEq(keeper.balance - before, ethOut, "keeper received ethOut");
        // SYA charged on actual delivered: 1000 USDe -> 1000e6 normalised, 10% discount
        assertEq(sya.totalCollected(), 900e6, "payment");
        assertEq(usdeStrategy.surplus(), 0, "strategy skimmed");
        assertEq(router.calls(address(usde)), 1, "router called once");
        _assertHarvesterEmpty();
    }

    function test_harvest_profitablePath_withLiveLikeOverEstimate() public {
        // Live calculateClaimAmount over-estimates by ~10% (set-aside buffer); the excess is repaid
        sya.setOverEstimateBps(1000);

        vm.prank(keeper);
        uint256 ethOut = harvester.harvest(_none(), 1, 0);

        assertGt(ethOut, 0, "ethOut");
        assertEq(sya.totalCollected(), 900e6, "payment on actual delivered");
        _assertHarvesterEmpty();
    }

    function test_harvest_minEthOutAboveOutput_reverts() public {
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        uint256 ethOut = harvester.harvest(_none(), 1, 0);
        vm.revertToState(snap);

        vm.expectRevert(abi.encodeWithSelector(SYAHarvester.InsufficientEthOut.selector, ethOut, ethOut + 1));
        vm.prank(keeper);
        harvester.harvest(_none(), 1, ethOut + 1);
    }

    /*//////////////////////////////////////////////////////////////
                         ROUTE COVERAGE AND SKIPS
    //////////////////////////////////////////////////////////////*/

    function test_harvest_unroutedToken_revertsRouteNotConfigured() public {
        _addStrategy(dola, DOLA_YIELD); // no route registered for DOLA

        vm.expectRevert(abi.encodeWithSelector(SYAHarvester.RouteNotConfigured.selector, address(dola)));
        vm.prank(keeper);
        harvester.harvest(_none(), 1, 0);
    }

    function test_harvest_rewardTokenStrategy_skippedNoRouterCall() public {
        usdcStrategy = _addStrategy(usdc, USDC_YIELD); // pays SYA's reward token directly, no route

        vm.prank(keeper);
        uint256 ethOut = harvester.harvest(_none(), 1, 0);

        assertGt(ethOut, 0, "ethOut");
        assertEq(router.calls(address(usdc)), 0, "router not called for reward token");
        assertEq(router.calls(address(usde)), 1, "router called for USDe");
        assertEq(usdcStrategy.surplus(), 0, "USDC strategy skimmed");
        // (1000e6 + 200e6) * 90%
        assertEq(sya.totalCollected(), 1080e6, "payment");
        _assertHarvesterEmpty();
    }

    function test_harvest_exemptStrategy_notSkimmedNotSold() public {
        dolaStrategy = _addStrategy(dola, DOLA_YIELD);
        dolaStrategy.setPaused(true); // a misbehaving strategy would revert the whole claim

        address[] memory exempt = new address[](1);
        exempt[0] = address(dolaStrategy);

        vm.prank(keeper);
        uint256 ethOut = harvester.harvest(exempt, 1, 0);

        assertGt(ethOut, 0, "ethOut");
        assertEq(dolaStrategy.surplus(), DOLA_YIELD, "exempt strategy untouched");
        assertEq(dola.balanceOf(address(dolaStrategy)), DOLA_YIELD, "exempt tokens stay in strategy");
        assertEq(router.calls(address(dola)), 0, "exempt token not sold");
        _assertHarvesterEmpty();
    }

    function test_harvest_pausedToken_skippedNoCoverageRevert() public {
        dolaStrategy = _addStrategy(dola, DOLA_YIELD); // no route registered for DOLA
        sya.pauseToken(address(dola));

        vm.prank(keeper);
        uint256 ethOut = harvester.harvest(_none(), 1, 0);

        assertGt(ethOut, 0, "ethOut");
        assertEq(dolaStrategy.surplus(), DOLA_YIELD, "paused strategy not skimmed");
        assertEq(router.calls(address(dola)), 0, "paused token not sold");
        _assertHarvesterEmpty();
    }

    /*//////////////////////////////////////////////////////////////
                              ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_unlockCallback_directCall_revertsNotPoolManager() public {
        vm.expectRevert(SYAHarvester.NotPoolManager.selector);
        vm.prank(stranger);
        harvester.unlockCallback(abi.encode(_none(), uint256(1)));
    }

    function test_receive_fromNonPoolManager_reverts() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(harvester).call{value: 1 ether}("");
        assertFalse(ok, "ETH from non-PoolManager accepted");
        assertEq(address(harvester).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 FAILURES
    //////////////////////////////////////////////////////////////*/

    function test_harvest_unprofitableClaim_reverts() public {
        // Sale proceeds (500 USDC) below the discounted payment (900 USDC): cannot repay the borrow
        router.setRate(address(usde), 0.5e6);

        // Surplus computation (balance - owed) underflows before the swap: the intended loud failure
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(keeper);
        harvester.harvest(_none(), 1, 0);
    }

    function test_harvest_nestedUnlockInSkimSurplus_reverts() public {
        usdeStrategy.setNestPoolManager(IPoolManager(address(manager)));

        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        vm.prank(keeper);
        harvester.harvest(_none(), 1, 0);
    }

    function test_harvest_ethPoolNotSet_reverts() public {
        SYAHarvester fresh = new SYAHarvester(
            owner,
            IPoolManager(address(manager)),
            IStableYieldAccumulator(address(sya)),
            ICurveRouterNG(address(router))
        );
        vm.expectRevert(SYAHarvester.EthPoolNotSet.selector);
        vm.prank(keeper);
        fresh.harvest(_none(), 1, 0);
    }
}
