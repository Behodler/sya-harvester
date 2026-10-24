// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdError} from "forge-std/StdError.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IStableYieldAccumulator} from "stable-yield-accumulator/src/interfaces/IStableYieldAccumulator.sol";

import {SYAHarvester} from "../src/SYAHarvester.sol";
import {ICurveRouterNG} from "../src/interfaces/ICurveRouterNG.sol";
import {MockSYA} from "./mocks/MockSYA.sol";
import {MockYieldStrategy} from "./mocks/MockYieldStrategy.sol";
import {MockCurveRouter} from "./mocks/MockCurveRouter.sol";

/// @notice Harvest flow against a real local Uniswap V4 PoolManager with mock SYA, strategies and router.
/// @dev Mock USDC uses 6 decimals (mainnet). The native-ETH/USDC pool is initialised at raw 1:1, so
///      1 raw USDC unit swaps for roughly 1 wei; only the relative sizes matter here.
contract SYAHarvesterHarvestTest is Deployers {
    SYAHarvester internal harvester;
    MockSYA internal sya;
    MockCurveRouter internal router;

    MockERC20 internal usdc;
    MockERC20 internal usde;
    MockERC20 internal dola;

    MockYieldStrategy internal usdeStrategy;
    MockYieldStrategy internal dolaStrategy;
    MockYieldStrategy internal usdcStrategy;

    PoolKey internal ethKey;

    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");
    address internal curvePool = makeAddr("curvePool");

    uint256 internal constant USDE_YIELD = 1000e18; // ~1000 USDC of value at rate 1:1
    uint256 internal constant DOLA_YIELD = 500e18;
    uint256 internal constant USDC_YIELD = 200e6;

    function setUp() public {
        deployFreshManagerAndRouters();

        usdc = new MockERC20("USD Coin", "USDC", 6);
        usde = new MockERC20("USDe", "USDe", 18);
        dola = new MockERC20("DOLA", "DOLA", 18);

        // Native-ETH / USDC pool with enough liquidity (~6e15 of each side) for every take/swap in the suite
        usdc.mint(address(this), 1e30);
        usdc.approve(address(modifyLiquidityRouter), type(uint256).max);
        (ethKey,) = initPoolAndAddLiquidityETH(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(usdc)), IHooks(address(0)), 3000, SQRT_PRICE_1_1, 1 ether
        );

        sya = new MockSYA(address(usdc));
        router = new MockCurveRouter();
        usdc.mint(address(router), 1e24);
        router.setRate(address(usde), 1e6); // 1 USDe -> 1 USDC
        router.setRate(address(dola), 1e6); // 1 DOLA -> 1 USDC

        harvester = new SYAHarvester(
            owner,
            IPoolManager(address(manager)),
            IStableYieldAccumulator(address(sya)),
            ICurveRouterNG(address(router))
        );

        usdeStrategy = _addStrategy(usde, USDE_YIELD);

        vm.startPrank(owner);
        harvester.setEthPool(ethKey);
        harvester.setRoute(address(usde), _path(address(usde)), _params(), _pools());
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _addStrategy(MockERC20 token, uint256 surplus) internal returns (MockYieldStrategy s) {
        s = new MockYieldStrategy(address(token));
        token.mint(address(s), surplus);
        s.setSurplus(surplus);
        sya.addYieldStrategy(address(s), address(token));
    }

    function _path(address tokenIn) internal view returns (address[11] memory p) {
        p[0] = tokenIn;
        p[1] = curvePool;
        p[2] = address(usdc);
    }

    function _params() internal pure returns (uint256[5][5] memory p) {
        p[0] = [uint256(0), 1, 1, 1, 2];
    }

    function _pools() internal pure returns (address[5] memory pools) {}

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _assertHarvesterEmpty() internal view {
        assertEq(address(harvester).balance, 0, "harvester ETH");
        assertEq(usdc.balanceOf(address(harvester)), 0, "harvester USDC");
        assertEq(usde.balanceOf(address(harvester)), 0, "harvester USDe");
        assertEq(dola.balanceOf(address(harvester)), 0, "harvester DOLA");
    }

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
