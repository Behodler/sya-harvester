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

    function test_setRoute_validatesAgainstCurrentRewardToken() public {
        sya.setRewardToken(other);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SYAHarvester.InvalidRouteEnd.selector, other, usdc));
        harvester.setRoute(usde, _singleHop(usde), _params(), _pools());
    }

    function test_setRoute_storesSingleHop() public {
        address[11] memory path = _singleHop(usde);
        uint256[5][5] memory params = _params();
        address[5] memory pools = _pools();

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
        harvester.setRoute(usde, _singleHop(usde), _params(), _pools());
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
        harvester.setRoute(usde, _singleHop(usde), _params(), _pools());

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
