// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {SYAHarvester} from "../../src/SYAHarvester.sol";
import {MainnetAddresses as A} from "./MainnetAddresses.sol";

/// @title MainnetRoutes
/// @notice Curve Router NG routes (yield token -> USDC) and the native-ETH/USDC Uniswap V4 pool key,
///         discovered on a mainnet fork at `MainnetAddresses.PINNED_BLOCK`. Reused by story 005.
/// @dev Router NG `swapParams` per hop: [i, j, swap_type, pool_type, n_coins].
///      swap_type 1 = exchange, 2 = exchange_underlying. pool_type 1 = stable, 10 = stableswap-ng.
///
///      Discovery (Curve MetaRegistry `find_pools_for_coins` + stableswap-ng factory
///      `find_pool_for_coins`, balances via `get_balances`, quotes via Router NG `get_dy`, all at the
///      pinned block):
///
///      crvUSD -> USDC candidates: 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E "crvUSD/USDC" factory plain
///      pool, ~2.93M USDC / ~10.1M crvUSD — by far the deepest (every other crvUSD/USDC pool held < 1.7M
///      and most were empty or test pools). Chosen.
///
///      DOLA -> USDC candidates (Router NG quote for 20 / 1000 / 5000 DOLA, USDC out):
///        - DOLA/FRAXBP metapool 0xE57180685E3348589E9521aa53Af0BCD497E884d, exchange_underlying DOLA->USDC
///          (5.28k DOLA / 10.8k FRAXBP LP; base FRAXBP 0xDcEF968d416a41Cdac0ED8702fAC8128A64241A2 holds
///          ~1.80M FRAX / ~199k USDC):                     19.945 / 996.17 / 4965.6   <- best, chosen
///        - DOLA/crvUSD 0x8272E1A3dBef607C04AA6e5BD3a1A134c8ac063B -> crvUSD/USDC 0x4DEc...:
///                                                         19.933 / 995.78 / 4905.2
///        - DOLA/3CRV metapools 0xAA5A67c2..., 0x9547429C... (underlying):  19.93 / 984.0, 19.93 / 959.6
///      The large DOLA pools (DOLA/sUSDe 0x744793B5..., DOLA/sUSDS 0x8b83c4aA...) do not reach USDC through
///      Curve without an ERC4626 redeem, which this Router NG rejects ("Bad swap type" for swap_type 9),
///      and sUSDe redemption has a cooldown, so they are not usable.
///
///      USDe -> USDC: hop 1 is the pool the live USDe strategy itself uses (MigrateStableStakerMainnet
///      `_setUsdeRoutes`). A direct USDe/USDC pool 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72 quoted
///      marginally better (19.9959 vs 19.9942 USDC for 20 USDe) and avoids the double fee below; it is a
///      drop-in alternative via `setRoute` if that difference ever matters. The story prescribes the
///      0xF55B... + crvUSD/USDC path, which is kept.
///
///      Double fee: the USDe strategy's own `skimSurplus` (sUSDe -> USDe through its CurveAMMAdapter ->
///      Router NG) and this route's first hop can both trade on 0xF55B... in the same transaction, paying
///      that pool's fee twice and moving its price against the second trade. Profitability only.
library MainnetRoutes {
    struct Route {
        address token;
        address[11] path;
        uint256[5][5] swapParams;
        address[5] pools;
    }

    // coin0 = USDe, coin1 = crvUSD (stableswap-ng)
    address internal constant POOL_USDE_CRVUSD = 0xF55B0f6F2Da5ffDDb104b58a60F2862745960442;
    // coin0 = USDC, coin1 = crvUSD (factory plain pool, pool_type 1)
    address internal constant POOL_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    // coin0 = DOLA, coin1 = FRAXBP LP; underlying: 0 = DOLA, 1 = FRAX, 2 = USDC (3 underlying coins)
    address internal constant POOL_DOLA_FRAXBP = 0xE57180685E3348589E9521aa53Af0BCD497E884d;

    /// @notice USDe -> crvUSD -> USDC
    function usdeRoute() internal pure returns (Route memory r) {
        r.token = A.USDE;
        r.path[0] = A.USDE;
        r.path[1] = POOL_USDE_CRVUSD;
        r.path[2] = A.CRVUSD;
        r.path[3] = POOL_CRVUSD_USDC;
        r.path[4] = A.USDC;
        // swapParams[0] = [0,1,1,10,2] — coin0(USDe) -> coin1(crvUSD), stableswap-ng exchange
        r.swapParams[0] = [uint256(0), 1, 1, 10, 2];
        // swapParams[1] = [1,0,1,1,2] — coin1(crvUSD) -> coin0(USDC), stable exchange
        r.swapParams[1] = [uint256(1), 0, 1, 1, 2];
    }

    /// @notice DOLA -> USDC through the DOLA/FRAXBP metapool's exchange_underlying
    function dolaRoute() internal pure returns (Route memory r) {
        r.token = A.DOLA;
        r.path[0] = A.DOLA;
        r.path[1] = POOL_DOLA_FRAXBP;
        r.path[2] = A.USDC;
        // swapParams[0] = [0,2,2,1,3] — underlying 0(DOLA) -> underlying 2(USDC), exchange_underlying,
        // stable metapool over 3 underlying coins; `pools` stays zero (only swap_type 3 uses a zap)
        r.swapParams[0] = [uint256(0), 2, 2, 1, 3];
    }

    /// @notice Native-ETH / USDC V4 pool, fee 3000 (0.30%), tickSpacing 60, no hooks.
    /// @dev In-range liquidity at the pinned block (StateLibrary.getLiquidity), hooks = 0:
    ///        fee 100/ts 1:   2.27e16
    ///        fee 500/ts 10:  1.37e17
    ///        fee 3000/ts 60: 7.21e17   <- deepest, chosen
    ///        fee 10000/ts 200: 1.19e13
    ///      For the ~$10 surplus of a typical harvest the 0.05% pool would charge less fee (~$0.025);
    ///      the owner can switch with `setEthPool` if that matters more than depth.
    function ethPoolKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(A.USDC),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    /// @notice Register every route and the ETH pool on `harvester`; the caller must be its owner
    function configure(SYAHarvester harvester) internal {
        Route memory u = usdeRoute();
        harvester.setRoute(u.token, u.path, u.swapParams, u.pools);
        Route memory d = dolaRoute();
        harvester.setRoute(d.token, d.path, d.swapParams, d.pools);
        harvester.setEthPool(ethPoolKey());
    }
}
