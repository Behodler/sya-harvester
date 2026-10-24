// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IStableYieldAccumulator} from "stable-yield-accumulator/src/interfaces/IStableYieldAccumulator.sol";

import {SYAHarvester} from "../../src/SYAHarvester.sol";
import {ICurveRouterNG} from "../../src/interfaces/ICurveRouterNG.sol";
import {MockSYA} from "../mocks/MockSYA.sol";
import {MockYieldStrategy} from "../mocks/MockYieldStrategy.sol";
import {MockCurveRouter} from "../mocks/MockCurveRouter.sol";

/// @notice Shared harness: a real local Uniswap V4 PoolManager with mock SYA, strategies and router.
/// @dev Mock USDC uses 6 decimals (mainnet). The native-ETH/USDC pool is initialised at raw 1:1, so
///      1 raw USDC unit swaps for roughly 1 wei; only the relative sizes matter here.
abstract contract HarvesterFixture is Deployers {
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

    function setUp() public virtual {
        deployFreshManagerAndRouters();

        usdc = new MockERC20("USD Coin", "USDC", 6);
        usde = new MockERC20("USDe", "USDe", 18);
        dola = new MockERC20("DOLA", "DOLA", 18);

        // Native-ETH / USDC pool with enough liquidity (~6e15 of each side) for every take/swap in the suite
        usdc.mint(address(this), 1e30);
        usdc.approve(address(modifyLiquidityRouter), type(uint256).max);
        (ethKey,) = initPoolAndAddLiquidityETH(
            CurrencyLibrary.ADDRESS_ZERO,
            Currency.wrap(address(usdc)),
            IHooks(address(0)),
            3000,
            SQRT_PRICE_1_1,
            1 ether
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
}
