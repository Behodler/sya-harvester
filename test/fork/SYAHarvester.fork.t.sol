// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IStableYieldAccumulator} from "stable-yield-accumulator/src/interfaces/IStableYieldAccumulator.sol";

import {SYAHarvester} from "../../src/SYAHarvester.sol";
import {ICurveRouterNG} from "../../src/interfaces/ICurveRouterNG.sol";
import {MainnetAddresses as A} from "./MainnetAddresses.sol";
import {MainnetRoutes} from "./MainnetRoutes.sol";
import {MockCurveRouter} from "../mocks/MockCurveRouter.sol";

interface ICurvePoolCoins {
    function coins(uint256 i) external view returns (address);
}

interface ICurveRouterNGQuote {
    function get_dy(
        address[11] calldata route,
        uint256[5][5] calldata swapParams,
        uint256 amount,
        address[5] calldata pools
    ) external view returns (uint256);
}

interface IStateView {
    function poolManager() external view returns (address);
}

interface ITotalSupply1155 {
    function totalSupply(uint256 id) external view returns (uint256);
}

/// @title SYAHarvesterForkTest
/// @notice Story 004: the complete harvester (001–003) against live mainnet state at a pinned block.
/// @dev Run with `MAINNET_RPC_URL` set to an ARCHIVE-capable endpoint (the block is pinned):
///        MAINNET_RPC_URL=<archive rpc> forge test --match-path test/fork/SYAHarvester.fork.t.sol -vv
///      Without `MAINNET_RPC_URL` every test in this contract is skipped (reported as skipped, not passed).
contract SYAHarvesterForkTest is Test, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Time warped forward from `PINNED_BLOCK`. Every live strategy already shows surplus at the pinned
    ///      block; the warp only lets it grow a little. It must stay SHORT: the USDC strategy's vault (Tokemak
    ///      autoUSD, 0x65efCF2cce562DCBf07e805eEbeDeF21Dbd8Ea3D) prices withdrawals through a root price oracle
    ///      that reads the Chainlink crvUSD/USD feed (0xEEf0C605546958c1f899b6fB336C20671f9cD49F) and reverts
    ///      `InvalidDataReturned()` once that feed is stale. The feed's `updatedAt` is ~13.3h old at the pinned
    ///      block, so a 7-day warp breaks every claim that includes the USDC strategy — a fork artifact (feeds are
    ///      updated on the live chain), not a harvester bug. 1 hour keeps the feed inside its window.
    uint256 internal constant ACCRUAL_WARP = 1 hours;
    /// @dev Gas price for the end-to-end harvest and the gas measurement. The base fee at the pinned block was
    ///      ~0.054 gwei; 1 gwei is ~18x that (generous priority-fee headroom). A full three-strategy harvest
    ///      burns ~2.6M gas (the USDC strategy's Tokemak autoUSD withdrawal dominates) and pays ~0.0045 ETH at
    ///      this block, so it breaks even near 1.7 gwei: at the story's example 2 gwei it is genuinely
    ///      unprofitable and reverts `Unprofitable` (see test_fork_harvest_highGasPrice_revertsUnprofitable).
    uint256 internal constant GAS_PRICE = 1 gwei;

    IStableYieldAccumulator internal sya = IStableYieldAccumulator(A.SYA);
    IPoolManager internal pm = IPoolManager(A.POOL_MANAGER);
    IERC1155 internal nft = IERC1155(A.NFT_MINTER);

    SYAHarvester internal harvester;
    address internal owner = makeAddr("harvesterOwner");
    address internal keeper = makeAddr("keeper");

    bool internal unlockCallbackHit;

    /// @dev FRAXBP (FRAX/USDC) base pool and its LP token, the DOLA metapool's coin1
    address internal constant FRAXBP_POOL = 0xDcEF968d416a41Cdac0ED8702fAC8128A64241A2;
    address internal constant FRAXBP_LP = 0x3175Df0976dFA876431C2E9eE6Bc45b65d3473CC;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            console2.log("MAINNET_RPC_URL unset: skipping the mainnet fork suite");
            vm.skip(true);
            return;
        }
        vm.createSelectFork(vm.rpcUrl("mainnet"), A.PINNED_BLOCK);

        harvester = new SYAHarvester(owner, pm, sya, ICurveRouterNG(A.CURVE_ROUTER_NG));
        vm.label(address(harvester), "SYAHarvester");
        vm.startPrank(owner);
        MainnetRoutes.configure(harvester);
        vm.stopPrank();

        // Claim NFT, method 1 of 3 (preferred): prank an existing holder of a valid index and transfer one
        // unit. NFT_HOLDER is an EOA with exactly 1 unit of index 1 at PINNED_BLOCK, so neither
        // `setAuthorizedMinter`+`mintFor` (method 2) nor the paid `mint` (method 3) is needed.
        vm.prank(A.NFT_HOLDER);
        nft.safeTransferFrom(A.NFT_HOLDER, keeper, A.NFT_INDEX, 1, "");
        vm.prank(keeper);
        nft.setApprovalForAll(address(harvester), true);

        // Accrual: time alone grows every live strategy's surplus (see test_fork_accrual_warpAloneProducesYield),
        // so no donation/simulated accrual is needed.
        vm.warp(block.timestamp + ACCRUAL_WARP);
        vm.roll(block.number + ACCRUAL_WARP / 12);
    }

    // ------------------------------------------------------------------ helpers

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        unlockCallbackHit = true;
        return "";
    }

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _one(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function _harvest(address[] memory exempt, uint256 minEthOut) internal returns (uint256) {
        vm.prank(keeper, keeper);
        return harvester.harvest(exempt, A.NFT_INDEX, minEthOut);
    }

    function _assertHarvesterEmpty() internal view {
        assertEq(address(harvester).balance, 0, "harvester ETH");
        assertEq(IERC20(A.USDC).balanceOf(address(harvester)), 0, "harvester USDC");
        assertEq(IERC20(A.DOLA).balanceOf(address(harvester)), 0, "harvester DOLA");
        assertEq(IERC20(A.USDE).balanceOf(address(harvester)), 0, "harvester USDe");
        assertEq(IERC20(A.CRVUSD).balanceOf(address(harvester)), 0, "harvester crvUSD");
        assertEq(IERC20(A.FRAX).balanceOf(address(harvester)), 0, "harvester FRAX");
        address[] memory strategies = sya.getYieldStrategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            address token = sya.strategyTokens(strategies[i]);
            assertEq(IERC20(token).balanceOf(address(harvester)), 0, "harvester strategy token");
        }
        assertEq(nft.balanceOf(address(harvester), A.NFT_INDEX), 0, "harvester NFT");
    }

    // ------------------------------------------------------------------ addresses

    function test_fork_addresses_verifiedOnFork() public {
        address[13] memory withCode = [
            A.SYA,
            A.YS_USDC,
            A.YS_USDE,
            A.YS_DOLA,
            A.NFT_MINTER,
            A.USDE_AMM_ADAPTER,
            A.USDC,
            A.DOLA,
            A.USDE,
            A.CRVUSD,
            A.CURVE_ROUTER_NG,
            A.POOL_MANAGER,
            A.V4_STATE_VIEW
        ];
        for (uint256 i = 0; i < withCode.length; i++) {
            assertGt(withCode[i].code.length, 0, "address has no code");
        }
        assertEq(sya.rewardToken(), A.USDC, "rewardToken");
        assertEq(sya.nftMinter(), A.NFT_MINTER, "nftMinter");
        assertEq(A.NFT_HOLDER.code.length, 0, "NFT holder is an EOA");

        // PoolManager is the v4 PoolManager: StateView points at it and `unlock` calls back the caller
        assertEq(IStateView(A.V4_STATE_VIEW).poolManager(), A.POOL_MANAGER, "StateView.poolManager");
        pm.unlock("");
        assertTrue(unlockCallbackHit, "unlock did not call back");

        uint256 rate = sya.getDiscountRate();
        console2.log("live SYA discount rate (bps):", rate);
        assertGt(rate, 0, "discount rate");
        assertLt(rate, 10_000, "discount rate");
    }

    function test_fork_liveStrategies_everyNonRewardTokenHasRoute() public view {
        address reward = sya.rewardToken();
        address[] memory strategies = sya.getYieldStrategies();
        assertEq(strategies.length, 3, "live strategy count differs from the address table");
        uint256 routed;
        for (uint256 i = 0; i < strategies.length; i++) {
            address token = sya.strategyTokens(strategies[i]);
            console2.log("strategy", strategies[i]);
            console2.log("  delivers token", token);
            if (token == reward) continue;
            assertTrue(harvester.getRoute(token).configured, "non-reward strategy token without a route");
            routed++;
        }
        assertEq(routed, 2, "USDe and DOLA routed");
        assertEq(sya.strategyTokens(A.YS_USDC), A.USDC);
        assertEq(sya.strategyTokens(A.YS_USDE), A.USDE);
        assertEq(sya.strategyTokens(A.YS_DOLA), A.DOLA);
    }

    // ------------------------------------------------------------------ routes and pool key

    function _quote(MainnetRoutes.Route memory r, uint256 amount) internal view returns (uint256) {
        return ICurveRouterNGQuote(A.CURVE_ROUTER_NG).get_dy(r.path, r.swapParams, amount, r.pools);
    }

    function test_fork_routes_coinIndicesMatchPools() public view {
        // USDe route: USDe -> crvUSD on 0xF55B..., crvUSD -> USDC on the discovered pool
        MainnetRoutes.Route memory u = MainnetRoutes.usdeRoute();
        assertEq(u.path[0], A.USDE);
        assertEq(ICurvePoolCoins(u.path[1]).coins(u.swapParams[0][0]), A.USDE, "usde hop1 i");
        assertEq(ICurvePoolCoins(u.path[1]).coins(u.swapParams[0][1]), A.CRVUSD, "usde hop1 j");
        assertEq(u.path[1], 0xF55B0f6F2Da5ffDDb104b58a60F2862745960442, "usde hop1 pool");
        assertEq(u.path[2], A.CRVUSD);
        assertEq(ICurvePoolCoins(u.path[3]).coins(u.swapParams[1][0]), A.CRVUSD, "usde hop2 i");
        assertEq(ICurvePoolCoins(u.path[3]).coins(u.swapParams[1][1]), A.USDC, "usde hop2 j");
        assertEq(u.path[4], A.USDC);

        // DOLA route: one exchange_underlying hop on the DOLA/FRAXBP metapool (DOLA=0, FRAX=1, USDC=2)
        MainnetRoutes.Route memory d = MainnetRoutes.dolaRoute();
        assertEq(d.path[0], A.DOLA);
        assertEq(ICurvePoolCoins(d.path[1]).coins(0), A.DOLA, "dola meta coin0");
        assertEq(ICurvePoolCoins(d.path[1]).coins(1), FRAXBP_LP, "dola meta coin1 is FRAXBP LP");
        address basePool = FRAXBP_POOL;
        assertEq(ICurvePoolCoins(basePool).coins(0), A.FRAX, "FRAXBP coin0");
        assertEq(ICurvePoolCoins(basePool).coins(1), A.USDC, "FRAXBP coin1 (underlying index 2)");
        assertEq(d.swapParams[0][1], 2, "USDC underlying index");
        assertEq(d.path[2], A.USDC);
    }

    function test_fork_routes_quoteCloseToPar() public view {
        // 20 tokens is the size of a real harvest; 1000 tokens shows the route still has depth
        uint256 u20 = _quote(MainnetRoutes.usdeRoute(), 20e18);
        uint256 d20 = _quote(MainnetRoutes.dolaRoute(), 20e18);
        uint256 d1000 = _quote(MainnetRoutes.dolaRoute(), 1000e18);
        console2.log("20 USDe -> USDC (6dp)", u20);
        console2.log("20 DOLA -> USDC (6dp)", d20);
        console2.log("1000 DOLA -> USDC (6dp)", d1000);
        assertGt(u20, 19.8e6, "USDe route quote");
        assertGt(d20, 19.8e6, "DOLA route quote");
        assertGt(d1000, 990e6, "DOLA route depth");
    }

    function test_fork_ethPool_isDeepestNativeEthUsdcPool() public view {
        PoolKey memory chosen = MainnetRoutes.ethPoolKey();
        assertEq(Currency.unwrap(chosen.currency0), address(0), "native ETH");
        assertEq(Currency.unwrap(chosen.currency1), A.USDC, "USDC");
        assertEq(address(chosen.hooks), address(0), "no hooks");
        uint128 chosenL = pm.getLiquidity(chosen.toId());
        assertGt(chosenL, 0, "chosen pool has liquidity");

        uint24[4] memory fees = [uint24(100), 500, 3000, 10_000];
        int24[4] memory spacings = [int24(1), 10, 60, 200];
        for (uint256 i = 0; i < fees.length; i++) {
            PoolKey memory k = PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(A.USDC),
                fee: fees[i],
                tickSpacing: spacings[i],
                hooks: IHooks(address(0))
            });
            uint128 l = pm.getLiquidity(k.toId());
            console2.log("fee", fees[i], "liquidity", l);
            assertLe(l, chosenL, "a candidate pool is deeper than the chosen one");
        }
        assertEq(harvester.getEthPool().fee, chosen.fee, "harvester configured with chosen key");
    }

    // ------------------------------------------------------------------ accrual

    function test_fork_accrual_warpAloneProducesYield() public view {
        address[] memory strategies = sya.getYieldStrategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 y = sya.getYield(strategies[i]);
            console2.log("pending yield", strategies[i], y);
            assertGt(y, 0, "strategy has no surplus after warp");
        }
        assertGt(sya.calculateClaimAmount(_none()), 0, "calculateClaimAmount");
    }

    // ------------------------------------------------------------------ end-to-end harvest

    function test_fork_harvest_endToEnd_paysEthBurnsNftLeavesNoBalances() public {
        uint256 keeperEthBefore = keeper.balance;
        uint256 nftBefore = nft.balanceOf(keeper, A.NFT_INDEX);
        uint256 supplyBefore = ITotalSupply1155(A.NFT_MINTER).totalSupply(A.NFT_INDEX);
        console2.log("calculateClaimAmount (USDC 6dp)", sya.calculateClaimAmount(_none()));

        vm.txGasPrice(GAS_PRICE);
        uint256 ethOut = _harvest(_none(), 1);

        console2.log("ETH paid to caller (wei)", ethOut);
        assertGt(ethOut, 0, "no ETH");
        assertEq(keeper.balance - keeperEthBefore, ethOut, "caller received ethOut");
        assertEq(nft.balanceOf(keeper, A.NFT_INDEX), nftBefore - 1, "caller NFT unit");
        assertEq(ITotalSupply1155(A.NFT_MINTER).totalSupply(A.NFT_INDEX), supplyBefore - 1, "NFT unit burned");
        _assertHarvesterEmpty();
    }

    /// @notice The USDe strategy's skimSurplus (ERC4626Market: sUSDe -> USDe via CurveAMMAdapter -> Router NG)
    ///         runs INSIDE the harvester's V4 unlock here. Any nested `poolManager.unlock` on that path would
    ///         revert `AlreadyUnlocked`, so a successful harvest with the USDe strategy non-exempt proves the
    ///         live strategy does not nest an unlock.
    /// @dev Double fee (profitability only, not correctness): the skim's sUSDe -> USDe leg and the harvester's
    ///      USDe -> crvUSD sale may both trade on pool 0xF55B0f6F2Da5ffDDb104b58a60F2862745960442 in this one
    ///      transaction, paying that pool's fee twice and moving its price against the second trade.
    function test_fork_harvest_usdeStrategyNonExempt_noNestedUnlock() public {
        assertGt(sya.getYield(A.YS_USDE), 0, "USDe strategy has surplus, so skimSurplus moves tokens");
        address[] memory exempt = new address[](2);
        exempt[0] = A.YS_USDC;
        exempt[1] = A.YS_DOLA;

        uint256 ethOut = _harvest(exempt, 1);
        assertGt(ethOut, 0, "USDe-only harvest paid ETH: no AlreadyUnlocked from a nested unlock");
        _assertHarvesterEmpty();
    }

    function test_fork_harvest_eachStrategyExemptedInTurn() public {
        address[] memory strategies = sya.getYieldStrategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 snap = vm.snapshotState();
            uint256 remaining = sya.calculateClaimAmount(_one(strategies[i]));
            if (remaining == 0) {
                // Exempting it leaves no yield: SYA reverts ZeroAmount inside the unlock
                vm.expectRevert(IStableYieldAccumulator.ZeroAmount.selector);
                _harvest(_one(strategies[i]), 0);
            } else {
                uint256 ethOut = _harvest(_one(strategies[i]), 1);
                console2.log("exempt", strategies[i], "ethOut", ethOut);
                assertGt(ethOut, 0, "harvest with one strategy exempt");
                _assertHarvesterEmpty();
            }
            vm.revertToState(snap);
        }
    }

    /// @dev At 2 gwei (the low end of a "busy mainnet" price, ~37x the pinned block's base fee) the full
    ///      harvest's ~2.78M charged gas costs ~0.0056 ETH against ~0.0046 ETH out: genuinely unprofitable.
    function test_fork_harvest_highGasPrice_revertsUnprofitable() public {
        vm.txGasPrice(2 gwei);
        vm.prank(keeper, keeper);
        (bool ok, bytes memory ret) =
            address(harvester).call(abi.encodeCall(harvester.harvest, (_none(), A.NFT_INDEX, 0)));
        assertFalse(ok, "should revert");
        assertEq(bytes4(ret), SYAHarvester.Unprofitable.selector, "Unprofitable");
    }

    function test_fork_harvest_excessiveMinEthOut_revertsInsufficientEthOut() public {
        vm.prank(keeper, keeper);
        (bool ok, bytes memory ret) =
            address(harvester).call(abi.encodeCall(harvester.harvest, (_none(), A.NFT_INDEX, 1000 ether)));
        assertFalse(ok, "should revert");
        assertEq(bytes4(ret), SYAHarvester.InsufficientEthOut.selector, "InsufficientEthOut");
    }

    // ------------------------------------------------------------------ GAS_OVERHEAD calibration

    function _calldataGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i = 0; i < data.length; i++) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    /// @notice GAS_OVERHEAD must cover the gap between the gas check's in-contract estimate
    ///         (`g0 - gasleft()` at the check) and the gas the transaction really burns.
    /// @dev Real gas is approximated as 21000 intrinsic + calldata + the gas the call consumed measured
    ///      around it here. That over-states a real transaction (the CALL into the harvester and the cold
    ///      `to` account are charged here but are free/warm in a real tx, and SSTORE refunds are not
    ///      deducted), so it is a conservative upper bound. The in-contract estimate comes from the
    ///      `Unprofitable(ethOut, gasCost)` revert at a huge gas price: `gasCost / price - GAS_OVERHEAD`.
    function test_fork_gasOverhead_coversMeasuredGap() public {
        bytes memory data = abi.encodeCall(harvester.harvest, (_none(), A.NFT_INDEX, 0));

        // 1) real gas of a successful harvest at a realistic gas price (measured first, cold)
        uint256 snap = vm.snapshotState();
        vm.txGasPrice(GAS_PRICE);
        vm.prank(keeper, keeper);
        uint256 before = gasleft();
        (bool ok,) = address(harvester).call(data);
        uint256 executionGas = before - gasleft();
        assertTrue(ok, "harvest");
        uint256 realGas = 21_000 + _calldataGas(data) + executionGas;
        vm.revertToState(snap);

        // 2) the in-contract estimate for the same harvest, read from the Unprofitable revert
        uint256 price = 1_000_000 gwei;
        vm.txGasPrice(price);
        vm.prank(keeper, keeper);
        bytes memory ret;
        (ok, ret) = address(harvester).call(data);
        assertFalse(ok, "expected Unprofitable");
        assertEq(bytes4(ret), SYAHarvester.Unprofitable.selector);
        uint256 gasCost;
        assembly {
            gasCost := mload(add(ret, 0x44))
        }
        uint256 inContract = gasCost / price - harvester.GAS_OVERHEAD();

        uint256 gap = realGas - inContract;
        console2.log("real gas (upper bound)", realGas);
        console2.log("in-contract estimate", inContract);
        console2.log("gap", gap);
        console2.log("GAS_OVERHEAD", harvester.GAS_OVERHEAD());
        assertGe(harvester.GAS_OVERHEAD(), gap, "GAS_OVERHEAD does not cover the measured gap");
        // and is not wildly padded: within 25k gas of the measured gap
        assertLe(harvester.GAS_OVERHEAD(), gap + 25_000, "GAS_OVERHEAD over-padded");
    }

    // ------------------------------------------------------------------ audit 01, M-01: Router NG contiguity

    /// @dev The audit's mis-entered USDe route: USDe -> [USDe/crvUSD] -> crvUSD -> <empty pool slot> ... USDC.
    ///      Router NG stops at the empty `path[3]` and delivers crvUSD; the trailing USDC is never reached.
    function _gapPath() internal pure returns (address[11] memory gap) {
        gap[0] = A.USDE;
        gap[1] = MainnetRoutes.POOL_USDE_CRVUSD;
        gap[2] = A.CRVUSD;
        gap[10] = A.USDC;
    }

    function test_fork_M01_gapRoute_rejectedBySetRoute() public {
        MainnetRoutes.Route memory u = MainnetRoutes.usdeRoute();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteGap(uint256)", 10));
        harvester.setRoute(A.USDE, _gapPath(), u.swapParams, u.pools);

        // the shipped contiguous route is still the one stored
        SYAHarvester.CurveRoute memory r = harvester.getRoute(A.USDE);
        assertEq(r.path[3], MainnetRoutes.POOL_CRVUSD_USDC, "contiguous route kept");
        assertEq(r.path[10], address(0));
    }

    function test_fork_M01_contiguousRoute_harvestsAndLeavesHarvesterEmpty() public {
        vm.txGasPrice(0); // isolate the route effect from the gas-profitability gate
        uint256 ethOut = _harvest(_none(), 0);
        assertGt(ethOut, 0, "harvest paid ETH");
        _assertHarvesterEmpty(); // includes crvUSD, the USDe route's intermediate token
    }

    /// @notice Ground truth for the unit-test double: the REAL Router NG, given the gap path, delivers crvUSD
    ///         (path[2]) and no USDC, and `MockCurveRouter` resolves the same path to the same token.
    function test_fork_M01_realRouterDeliversIntermediate_mockAgrees() public {
        MainnetRoutes.Route memory u = MainnetRoutes.usdeRoute();
        address[11] memory gap = _gapPath();
        uint256 amount = 1_000e18;

        // real Router NG
        deal(A.USDE, address(this), amount);
        IERC20(A.USDE).approve(A.CURVE_ROUTER_NG, amount);
        uint256 crvBefore = IERC20(A.CRVUSD).balanceOf(address(this));
        uint256 usdcBefore = IERC20(A.USDC).balanceOf(address(this));
        uint256 out = ICurveRouterNG(A.CURVE_ROUTER_NG).exchange(gap, u.swapParams, amount, 0, u.pools, address(this));
        uint256 crvGot = IERC20(A.CRVUSD).balanceOf(address(this)) - crvBefore;
        assertGt(out, 0, "router output");
        assertEq(crvGot, out, "real Router NG delivered crvUSD (path[2])");
        assertEq(IERC20(A.USDC).balanceOf(address(this)), usdcBefore, "real Router NG delivered no USDC");

        // the unit-test double resolves the same path to the same token
        MockCurveRouter mock = new MockCurveRouter();
        mock.setRate(A.USDE, 1e18);
        deal(A.CRVUSD, address(mock), amount);
        deal(A.USDC, address(mock), amount);
        deal(A.USDE, address(this), amount);
        IERC20(A.USDE).approve(address(mock), amount);
        crvBefore = IERC20(A.CRVUSD).balanceOf(address(this));
        mock.exchange(gap, u.swapParams, amount, 0, u.pools, address(this));
        assertEq(IERC20(A.CRVUSD).balanceOf(address(this)) - crvBefore, amount, "mock delivered crvUSD too");
        assertEq(IERC20(A.USDC).balanceOf(address(this)), usdcBefore, "mock delivered no USDC");
    }

    // ------------------------------------------------------------------ audit 01: M-01 residual + mitigation 2

    /// @dev USDe -> [USDe/crvUSD] -> address(0) -> [crvUSD/USDC] -> USDC: the executed prefix delivers USDC, but
    ///      hop 0's output token slot is empty.
    function _zeroIntermediatePath() internal pure returns (address[11] memory p) {
        p[0] = A.USDE;
        p[1] = MainnetRoutes.POOL_USDE_CRVUSD;
        p[3] = MainnetRoutes.POOL_CRVUSD_USDC;
        p[4] = A.USDC;
    }

    /// @dev Calls the REAL Router NG with `amount` USDe from this contract; returns success and revert data
    function _realRouterExchange(address[11] memory path, uint256[5][5] memory params, uint256 amount)
        internal
        returns (bool ok, bytes memory ret)
    {
        address[5] memory pools;
        deal(A.USDE, address(this), amount);
        IERC20(A.USDE).approve(A.CURVE_ROUTER_NG, amount);
        (ok, ret) = A.CURVE_ROUTER_NG
            .call(abi.encodeCall(ICurveRouterNG.exchange, (path, params, amount, 0, pools, address(this))));
    }

    /// @dev Same call against `MockCurveRouter`, funded with every token the path could resolve to
    function _mockExchange(address[11] memory path, uint256[5][5] memory params, uint256 amount)
        internal
        returns (bool ok, bytes memory ret)
    {
        address[5] memory pools;
        MockCurveRouter mock = new MockCurveRouter();
        mock.setRate(A.USDE, 1e18);
        deal(A.CRVUSD, address(mock), amount);
        deal(A.USDC, address(mock), amount);
        deal(A.USDE, address(this), amount);
        IERC20(A.USDE).approve(address(mock), amount);
        (ok, ret) = address(mock).call(abi.encodeCall(mock.exchange, (path, params, amount, 0, pools, address(this))));
    }

    /// @notice Ground truth: the real Router NG REVERTS (empty revert data) on a zero intermediate token inside
    ///         the executed prefix, and the mock reverts too.
    function test_fork_zeroIntermediate_realRouterReverts_mockAgrees() public {
        MainnetRoutes.Route memory u = MainnetRoutes.usdeRoute();
        uint256 usdcBefore = IERC20(A.USDC).balanceOf(address(this));

        (bool ok, bytes memory ret) = _realRouterExchange(_zeroIntermediatePath(), u.swapParams, 1_000e18);
        console2.log("real Router NG, zero intermediate: reverted =", !ok);
        console2.logBytes(ret);
        assertFalse(ok, "real Router NG reverts on a zero intermediate token");
        // observed at PINNED_BLOCK: empty revert data (a call to the code-less address(0) as the hop-0 output token)
        assertEq(ret.length, 0, "real Router NG revert data is empty");
        assertEq(IERC20(A.USDC).balanceOf(address(this)), usdcBefore, "no USDC delivered");

        (ok, ret) = _mockExchange(_zeroIntermediatePath(), u.swapParams, 1_000e18);
        assertFalse(ok, "mock reverts too");
        assertEq(ret, abi.encodeWithSignature("ZeroIntermediateToken()"));
    }

    /// @notice Ground truth: the real Router NG REVERTS `Error("Bad swap type")` when an executed hop's swap_type
    ///         is 0, and the mock reverts too.
    function test_fork_zeroSwapTypeOnExecutedHop_realRouterReverts_mockAgrees() public {
        MainnetRoutes.Route memory u = MainnetRoutes.usdeRoute();
        uint256[5][5] memory params = u.swapParams;
        params[1][2] = 0; // hop 1 (crvUSD -> USDC) executed with swap_type 0

        (bool ok, bytes memory ret) = _realRouterExchange(u.path, params, 1_000e18);
        console2.log("real Router NG, swap_type 0 on hop 1: reverted =", !ok);
        console2.logBytes(ret);
        assertFalse(ok, "real Router NG reverts on swap_type 0 for an executed hop");
        // observed at PINNED_BLOCK: Router NG's own dispatch rejects the unknown swap type
        assertEq(ret, abi.encodeWithSignature("Error(string)", "Bad swap type"), "real Router NG: Bad swap type");

        (ok, ret) = _mockExchange(u.path, params, 1_000e18);
        assertFalse(ok, "mock reverts too");
        assertEq(ret, abi.encodeWithSignature("BadSwapType(uint256)", 1));
    }

    function test_fork_zeroIntermediate_rejectedBySetRoute() public {
        MainnetRoutes.Route memory u = MainnetRoutes.usdeRoute();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidRouteToken(uint256)", 2));
        harvester.setRoute(A.USDE, _zeroIntermediatePath(), u.swapParams, u.pools);

        SYAHarvester.CurveRoute memory r = harvester.getRoute(A.USDE);
        assertEq(r.path[2], A.CRVUSD, "shipped route kept");
    }

    /// @notice The shipped routes satisfy every setRoute rule (configure re-runs cleanly) and still harvest
    ///         to an empty harvester.
    function test_fork_shippedRoutes_passNewRules_andHarvestLeavesHarvesterEmpty() public {
        vm.startPrank(owner);
        MainnetRoutes.configure(harvester);
        vm.stopPrank();

        vm.txGasPrice(0);
        uint256 ethOut = _harvest(_none(), 0);
        assertGt(ethOut, 0, "harvest paid ETH");
        _assertHarvesterEmpty();
    }
}
