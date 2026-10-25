// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IStableYieldAccumulator} from "stable-yield-accumulator/src/interfaces/IStableYieldAccumulator.sol";

import {SYAHarvester} from "../src/SYAHarvester.sol";
import {ICurveRouterNG} from "../src/interfaces/ICurveRouterNG.sol";
import {MockSYA} from "./mocks/MockSYA.sol";

contract SYAHarvesterRegistryTest is Test {
    event RouteSet(address indexed token);
    event RouteCleared(address indexed token);
    event EthPoolSet(address indexed currency0, address indexed currency1, uint24 fee, int24 tickSpacing, address hooks);

    SYAHarvester internal harvester;
    MockSYA internal sya;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    address internal poolManager = makeAddr("poolManager");
    address internal router = makeAddr("router");

    address internal usdc = makeAddr("usdc");
    address internal usde = makeAddr("usde");
    address internal dola = makeAddr("dola");
    address internal other = makeAddr("other");
    address internal other2 = makeAddr("other2");
    address internal other3 = makeAddr("other3");
    address internal pool0 = makeAddr("pool0");
    address internal pool1 = makeAddr("pool1");

    function setUp() public {
        sya = new MockSYA(usdc);
        harvester = new SYAHarvester(
            owner, IPoolManager(poolManager), IStableYieldAccumulator(address(sya)), ICurveRouterNG(router)
        );
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _singleHop(address tokenIn) internal view returns (address[11] memory path) {
        path[0] = tokenIn;
        path[1] = pool0;
        path[2] = usdc;
    }

    function _multiHop(address tokenIn) internal view returns (address[11] memory path) {
        path[0] = tokenIn;
        path[1] = pool0;
        path[2] = other;
        path[3] = pool1;
        path[4] = usdc;
    }

    function _params() internal pure returns (uint256[5][5] memory p) {
        p[0] = [uint256(0), 1, 1, 1, 2];
        p[1] = [uint256(1), 0, 1, 10, 2];
    }

    function _pools() internal view returns (address[5] memory pools) {
        pools[0] = pool1;
    }

    /// @dev Swap params consistent with a route executing `k` hops: rows 0..k-1 carry a non-zero swap_type
    ///      (rows 0 and 1 are exactly `_params()`), rows k..4 are all zero (audit 01, mitigation 2).
    function _params(uint256 k) internal pure returns (uint256[5][5] memory p) {
        for (uint256 h = 0; h < k; h++) {
            p[h] = h == 1 ? [uint256(1), 0, 1, 10, 2] : [uint256(0), 1, 1, 1, 2];
        }
    }

    /// @dev Pools consistent with a route executing `k` hops: `pools[0] = pool1` is legal for an executed hop
    ///      (k >= 1); every slot k..4 is zero.
    function _pools(uint256 k) internal view returns (address[5] memory pools) {
        if (k >= 1) pools[0] = pool1;
    }

    function _ethKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(usdc),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_storesImmutablesAndOwner() public view {
        assertEq(harvester.owner(), owner);
        assertEq(address(harvester.poolManager()), poolManager);
        assertEq(address(harvester.sya()), address(sya));
        assertEq(address(harvester.router()), router);
    }

    function test_constructor_rejectsZeroPoolManager() public {
        vm.expectRevert(SYAHarvester.ZeroAddress.selector);
        new SYAHarvester(owner, IPoolManager(address(0)), IStableYieldAccumulator(address(sya)), ICurveRouterNG(router));
    }

    function test_constructor_rejectsZeroSya() public {
        vm.expectRevert(SYAHarvester.ZeroAddress.selector);
        new SYAHarvester(owner, IPoolManager(poolManager), IStableYieldAccumulator(address(0)), ICurveRouterNG(router));
    }

    function test_constructor_rejectsZeroRouter() public {
        vm.expectRevert(SYAHarvester.ZeroAddress.selector);
        new SYAHarvester(
            owner, IPoolManager(poolManager), IStableYieldAccumulator(address(sya)), ICurveRouterNG(address(0))
        );
    }

    function test_constructor_rejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new SYAHarvester(
            address(0), IPoolManager(poolManager), IStableYieldAccumulator(address(sya)), ICurveRouterNG(router)
        );
    }

    /*//////////////////////////////////////////////////////////////
                              ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_setRoute_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        harvester.setRoute(usde, _singleHop(usde), _params(), _pools());
    }

    function test_clearRoute_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        harvester.clearRoute(usde);
    }

    function test_setEthPool_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        harvester.setEthPool(_ethKey());
    }

    /*//////////////////////////////////////////////////////////////
                                SET ROUTE
    //////////////////////////////////////////////////////////////*/

    function test_setRoute_rejectsZeroToken() public {
        address[11] memory path = _singleHop(address(0));
        vm.prank(owner);
        vm.expectRevert(SYAHarvester.ZeroAddress.selector);
        harvester.setRoute(address(0), path, _params(), _pools());
    }

    function test_setRoute_rejectsWrongFirstToken() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SYAHarvester.InvalidRouteStart.selector, usde, dola));
        harvester.setRoute(usde, _singleHop(dola), _params(), _pools());
    }

    function test_setRoute_rejectsRouteEndingAtNonRewardToken() public {
        address[11] memory path;
        path[0] = usde;
        path[1] = pool0;
        path[2] = other;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SYAHarvester.InvalidRouteEnd.selector, usdc, other));
        harvester.setRoute(usde, path, _params(), _pools());
    }

    function test_setRoute_rejectsMultiHopEndingAtWrongToken() public {
        address[11] memory path = _multiHop(usde);
        path[4] = dola;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SYAHarvester.InvalidRouteEnd.selector, usdc, dola));
        harvester.setRoute(usde, path, _params(), _pools());
    }

    /*//////////////////////////////////////////////////////////////
               ROUTER NG CONTIGUITY (audit 01, M-01)
    //////////////////////////////////////////////////////////////*/

    /// @dev Router NG executes hop k while `path[2k+1] != 0` and delivers `path[2k]` at the first empty
    ///      pool slot, so these entries are what the route actually does.
    function _fiveHop(address tokenIn, address tokenOut) internal view returns (address[11] memory path) {
        path[0] = tokenIn;
        path[1] = pool0;
        path[2] = other;
        path[3] = pool1;
        path[4] = dola;
        path[5] = pool0;
        path[6] = other2;
        path[7] = pool1;
        path[8] = other3;
        path[9] = pool0;
        path[10] = tokenOut;
    }

    function test_setRoute_rejectsGappedRoute_trailingRewardToken() public {
        // The audit's mis-entered route: Router NG stops at path[3] == 0 and delivers `other`; the trailing
        // reward token at path[10] is never reached. The gap is reported first (it is the root cause).
        address[11] memory path;
        path[0] = usde;
        path[1] = pool0;
        path[2] = other;
        path[10] = usdc;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteGap(uint256)", 10));
        harvester.setRoute(usde, path, _params(), _pools());
    }

    function test_setRoute_rejectsGappedRoute_whenDeliveredIsRewardButTrailingEntry() public {
        // The executed prefix already ends at the reward token; a duplicate trailing reward entry is still
        // a non-executed entry and is rejected.
        address[11] memory path;
        path[0] = usde;
        path[1] = pool0;
        path[2] = usdc;
        path[10] = usdc;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteGap(uint256)", 10));
        harvester.setRoute(usde, path, _params(), _pools());
    }

    function test_setRoute_rejectsStrayEntryAfterRewardToken() public {
        address[11] memory path = _singleHop(usde);
        path[4] = other; // never executed: path[3] == 0 ends the route at path[2]
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteGap(uint256)", 4));
        harvester.setRoute(usde, path, _params(), _pools());
    }

    function test_setRoute_rejectsGapInMultiHopRoute() public {
        address[11] memory path;
        path[0] = usde;
        path[1] = pool0;
        path[2] = other;
        path[3] = pool1;
        path[4] = usdc;
        path[6] = usdc; // path[5] == 0: the route ends at path[4]; path[6] is a trailing entry
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteGap(uint256)", 6));
        harvester.setRoute(usde, path, _params(), _pools());
    }

    function test_setRoute_rejectsGapInMultiHopRoute_deliveringIntermediate() public {
        // [usde, pool0, other, pool1, other2, 0, usdc, 0...]: Router NG delivers `other2` (path[4]); the
        // trailing reward token at path[6] is never reached.
        address[11] memory path;
        path[0] = usde;
        path[1] = pool0;
        path[2] = other;
        path[3] = pool1;
        path[4] = other2;
        path[6] = usdc;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteGap(uint256)", 6));
        harvester.setRoute(usde, path, _params(), _pools());
    }

    function test_setRoute_rejectsTrailingPoolSlotAfterRewardToken() public {
        address[11] memory path = _singleHop(usde);
        path[5] = pool1; // a pool slot after the executed prefix is still a trailing entry
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteGap(uint256)", 5));
        harvester.setRoute(usde, path, _params(), _pools());
    }

    function test_setRoute_storesFullFiveHopRoute() public {
        address[11] memory path = _fiveHop(usde, usdc);
        vm.prank(owner);
        harvester.setRoute(usde, path, _params(5), _pools(5));

        SYAHarvester.CurveRoute memory r = harvester.getRoute(usde);
        assertTrue(r.configured);
        for (uint256 i = 0; i < 11; i++) {
            assertEq(r.path[i], path[i]);
        }
    }

    function test_setRoute_rejectsFiveHopEndingAtNonRewardToken() public {
        address[11] memory path = _fiveHop(usde, other);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SYAHarvester.InvalidRouteEnd.selector, usdc, other));
        harvester.setRoute(usde, path, _params(5), _pools(5));
    }

    function test_setRoute_rejectsNoHopRouteForNonRewardToken() public {
        // path[1] == 0: Router NG executes nothing; the "delivered" token is path[0] itself
        address[11] memory path;
        path[0] = usde;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SYAHarvester.InvalidRouteEnd.selector, usdc, usde));
        harvester.setRoute(usde, path, _params(), _pools());
    }

    function test_setRoute_rejectsNoHopRouteWithTrailingRewardToken() public {
        // path[1] == 0 with a trailing reward token: nothing executes, path[2] is a trailing entry
        address[11] memory path;
        path[0] = usde;
        path[2] = usdc;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteGap(uint256)", 2));
        harvester.setRoute(usde, path, _params(), _pools());
    }

    /// @dev Documented harmless case: a reward-token "route" with no hop (k = 0) delivers path[0] = reward.
    ///      `_sellYield` skips the reward token, so this route is never executed.
    function test_setRoute_acceptsNoHopRouteForRewardToken() public {
        address[11] memory path;
        path[0] = usdc;
        vm.prank(owner);
        harvester.setRoute(usdc, path, _params(0), _pools(0));

        SYAHarvester.CurveRoute memory r = harvester.getRoute(usdc);
        assertTrue(r.configured);
        assertEq(r.path[0], usdc);
        assertEq(r.path[1], address(0));
    }

    function test_setRoute_rejectsNoHopRewardRouteWithTrailingEntry() public {
        address[11] memory path;
        path[0] = usdc;
        path[2] = other;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteGap(uint256)", 2));
        harvester.setRoute(usdc, path, _params(), _pools());
    }

    function test_setRoute_validatesAgainstCurrentRewardToken() public {
        sya.setRewardToken(other);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SYAHarvester.InvalidRouteEnd.selector, other, usdc));
        harvester.setRoute(usde, _singleHop(usde), _params(), _pools());
    }

    function test_setRoute_storesSingleHop() public {
        address[11] memory path = _singleHop(usde);
        uint256[5][5] memory params = _params(1);
        address[5] memory pools = _pools(1);

        vm.prank(owner);
        harvester.setRoute(usde, path, params, pools);

        SYAHarvester.CurveRoute memory r = harvester.getRoute(usde);
        assertTrue(r.configured);
        for (uint256 i = 0; i < 11; i++) {
            assertEq(r.path[i], path[i]);
        }
        for (uint256 i = 0; i < 5; i++) {
            assertEq(r.pools[i], pools[i]);
            for (uint256 j = 0; j < 5; j++) {
                assertEq(r.swapParams[i][j], params[i][j]);
            }
        }
    }

    function test_setRoute_storesMultiHop() public {
        address[11] memory path = _multiHop(dola);

        vm.prank(owner);
        harvester.setRoute(dola, path, _params(), _pools());

        SYAHarvester.CurveRoute memory r = harvester.getRoute(dola);
        assertTrue(r.configured);
        assertEq(r.path[0], dola);
        assertEq(r.path[2], other);
        assertEq(r.path[4], usdc);
        assertEq(r.path[5], address(0));
        assertEq(r.swapParams[1][3], 10);
    }

    function test_setRoute_emitsRouteSet() public {
        vm.expectEmit(true, false, false, true, address(harvester));
        emit RouteSet(usde);
        vm.prank(owner);
        harvester.setRoute(usde, _singleHop(usde), _params(1), _pools(1));
    }

    /*//////////////////////////////////////////////////////////////
        ROUTE TOKEN / SWAP PARAMS / POOLS CONSISTENCY (audit 01, M-01 residual + mitigation 2)
    //////////////////////////////////////////////////////////////*/

    function test_setRoute_rejectsZeroIntermediateToken_twoHop() public {
        // [usde, pool0, 0, pool1, usdc, 0...]: the executed prefix delivers usdc but hop 0 outputs address(0)
        address[11] memory path;
        path[0] = usde;
        path[1] = pool0;
        path[3] = pool1;
        path[4] = usdc;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteToken(uint256)", 2));
        harvester.setRoute(usde, path, _params(2), _pools(2));
    }

    function test_setRoute_rejectsZeroIntermediateToken_index6InFourHop() public {
        address[11] memory path;
        path[0] = usde;
        path[1] = pool0;
        path[2] = other;
        path[3] = pool1;
        path[4] = dola;
        path[5] = pool0;
        // path[6] == 0: hop 2 outputs address(0)
        path[7] = pool1;
        path[8] = usdc;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteToken(uint256)", 6));
        harvester.setRoute(usde, path, _params(4), _pools(4));
    }

    function test_setRoute_zeroIntermediateReportedBeforeWrongEnd() public {
        address[11] memory path = _multiHop(usde);
        path[2] = address(0);
        path[4] = other; // also delivers a non-reward token: the zero intermediate is reported first
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteToken(uint256)", 2));
        harvester.setRoute(usde, path, _params(2), _pools(2));
    }

    function test_setRoute_rejectsExecutedRowWithZeroSwapType_singleHop() public {
        uint256[5][5] memory p = _params(1);
        p[0][2] = 0;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteSwapParams(uint256)", 0));
        harvester.setRoute(usde, _singleHop(usde), p, _pools(1));
    }

    function test_setRoute_rejectsExecutedRowWithZeroSwapType_secondHop() public {
        uint256[5][5] memory p = _params(2);
        p[1][2] = 0; // i/j/pool_type/n_coins still set: only swap_type decides "executed row non-empty"
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteSwapParams(uint256)", 1));
        harvester.setRoute(usde, _multiHop(usde), p, _pools(2));
    }

    function test_setRoute_rejectsAllZeroExecutedRow_fiveHop() public {
        uint256[5][5] memory p = _params(5);
        delete p[4];
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteSwapParams(uint256)", 4));
        harvester.setRoute(usde, _fiveHop(usde, usdc), p, _pools(5));
    }

    function test_setRoute_rejectsRowAtHopK_singleHop() public {
        // single-hop with row 1 set (the old two-row `_params()`): row 1 is never executed
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteSwapParams(uint256)", 1));
        harvester.setRoute(usde, _singleHop(usde), _params(), _pools(1));
    }

    function test_setRoute_rejectsSingleNonZeroFieldInUnexecutedRow() public {
        // a non-executed row with only its `i` field set is still non-zero
        uint256[5][5] memory p = _params(1);
        p[3][0] = 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteSwapParams(uint256)", 3));
        harvester.setRoute(usde, _singleHop(usde), p, _pools(1));
    }

    function test_setRoute_rejectsPoolAtHopK_singleHop() public {
        address[5] memory pools = _pools(1);
        pools[1] = pool1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRoutePools(uint256)", 1));
        harvester.setRoute(usde, _singleHop(usde), _params(1), pools);
    }

    function test_setRoute_rejectsPoolInLastSlot_twoHop() public {
        address[5] memory pools = _pools(2);
        pools[4] = pool0;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRoutePools(uint256)", 4));
        harvester.setRoute(usde, _multiHop(usde), _params(2), pools);
    }

    function test_setRoute_unexecutedHopChecksParamsBeforePools() public {
        // hop 1 (k = 1) has both a stray row and a stray pool: the row is reported
        address[5] memory pools = _pools(1);
        pools[1] = pool1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteSwapParams(uint256)", 1));
        harvester.setRoute(usde, _singleHop(usde), _params(), pools);
    }

    function test_setRoute_unexecutedHopsAreCheckedInHopOrder() public {
        // stray pool at hop 1 and stray row at hop 2 (k = 1): hop 1 is checked first
        uint256[5][5] memory p = _params(1);
        p[2][2] = 1;
        address[5] memory pools = _pools(1);
        pools[1] = pool1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRoutePools(uint256)", 1));
        harvester.setRoute(usde, _singleHop(usde), p, pools);
    }

    function test_setRoute_wrongEndReportedBeforeSwapParams() public {
        address[11] memory path = _singleHop(usde);
        path[2] = other;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SYAHarvester.InvalidRouteEnd.selector, usdc, other));
        harvester.setRoute(usde, path, _params(), _pools());
    }

    function test_setRoute_rejectsNoHopRewardRouteWithNonZeroRow() public {
        address[11] memory path;
        path[0] = usdc;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteSwapParams(uint256)", 0));
        harvester.setRoute(usdc, path, _params(1), _pools(0));
    }

    function test_setRoute_rejectsNoHopRewardRouteWithNonZeroPool() public {
        address[11] memory path;
        path[0] = usdc;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRoutePools(uint256)", 0));
        harvester.setRoute(usdc, path, _params(0), _pools(1));
    }

    function test_setRoute_storesFullFiveHopRouteWithFiveValidRows() public {
        address[11] memory path = _fiveHop(usde, usdc);
        uint256[5][5] memory p = _params(5);
        vm.prank(owner);
        harvester.setRoute(usde, path, p, _pools(5));

        SYAHarvester.CurveRoute memory r = harvester.getRoute(usde);
        assertTrue(r.configured);
        for (uint256 h = 0; h < 5; h++) {
            assertGt(r.swapParams[h][2], 0, "executed row has a swap type");
            for (uint256 f = 0; f < 5; f++) {
                assertEq(r.swapParams[h][f], p[h][f]);
            }
        }
    }

    function test_setRoute_storesSingleHopWithOnlyRowZeroAndZeroPools() public {
        address[11] memory path = _singleHop(usde);
        uint256[5][5] memory p = _params(1);
        address[5] memory pools;
        vm.prank(owner);
        harvester.setRoute(usde, path, p, pools);

        SYAHarvester.CurveRoute memory r = harvester.getRoute(usde);
        assertTrue(r.configured);
        for (uint256 i = 0; i < 11; i++) {
            assertEq(r.path[i], path[i]);
        }
        for (uint256 h = 0; h < 5; h++) {
            assertEq(r.pools[h], address(0));
            for (uint256 f = 0; f < 5; f++) {
                assertEq(r.swapParams[h][f], p[h][f]);
            }
        }
    }

    function test_setRoute_acceptsNoHopRewardRouteWithAllZeroParamsAndPools() public {
        address[11] memory path;
        path[0] = usdc;
        uint256[5][5] memory p;
        address[5] memory pools;
        vm.prank(owner);
        harvester.setRoute(usdc, path, p, pools);
        assertTrue(harvester.getRoute(usdc).configured);
    }

    function test_getRoute_unsetTokenIsNotConfigured() public view {
        SYAHarvester.CurveRoute memory r = harvester.getRoute(usde);
        assertFalse(r.configured);
        assertEq(r.path[0], address(0));
    }

    /*//////////////////////////////////////////////////////////////
                               CLEAR ROUTE
    //////////////////////////////////////////////////////////////*/

    function test_clearRoute_resetsConfiguredAndEmits() public {
        vm.prank(owner);
        harvester.setRoute(usde, _singleHop(usde), _params(1), _pools(1));

        vm.expectEmit(true, false, false, true, address(harvester));
        emit RouteCleared(usde);
        vm.prank(owner);
        harvester.clearRoute(usde);

        SYAHarvester.CurveRoute memory r = harvester.getRoute(usde);
        assertFalse(r.configured);
        assertEq(r.path[0], address(0));
        assertEq(r.swapParams[0][4], 0);
        assertEq(r.pools[0], address(0));
    }

    /*//////////////////////////////////////////////////////////////
                               SET ETH POOL
    //////////////////////////////////////////////////////////////*/

    function test_setEthPool_rejectsNonNativeCurrency0() public {
        PoolKey memory key = _ethKey();
        key.currency0 = Currency.wrap(other);
        vm.prank(owner);
        vm.expectRevert(SYAHarvester.InvalidEthPool.selector);
        harvester.setEthPool(key);
    }

    function test_setEthPool_rejectsCurrency1NotRewardToken() public {
        PoolKey memory key = _ethKey();
        key.currency1 = Currency.wrap(other);
        vm.prank(owner);
        vm.expectRevert(SYAHarvester.InvalidEthPool.selector);
        harvester.setEthPool(key);
    }

    function test_setEthPool_storesKeyAndEmits() public {
        PoolKey memory key = _ethKey();

        vm.expectEmit(true, true, false, true, address(harvester));
        emit EthPoolSet(address(0), usdc, 500, 10, address(0));
        vm.prank(owner);
        harvester.setEthPool(key);

        PoolKey memory stored = harvester.getEthPool();
        assertEq(Currency.unwrap(stored.currency0), address(0));
        assertEq(Currency.unwrap(stored.currency1), usdc);
        assertEq(stored.fee, 500);
        assertEq(stored.tickSpacing, 10);
        assertEq(address(stored.hooks), address(0));
    }

    function test_noHarvestFunction() public {
        (bool ok,) = address(harvester).call(abi.encodeWithSignature("harvest(uint256,uint256,address[])", 0, 0, new address[](0)));
        assertFalse(ok);
    }
}
