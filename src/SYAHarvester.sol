// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IStableYieldAccumulator} from "stable-yield-accumulator/src/interfaces/IStableYieldAccumulator.sol";
import {ICurveRouterNG} from "./interfaces/ICurveRouterNG.sol";

/**
 * @title SYAHarvester
 * @notice Flash-loan helper that claims from StableYieldAccumulator (SYA), sells the yield tokens it
 *         receives to SYA's reward token along owner-registered Curve Router NG routes, swaps the
 *         surplus to native ETH in a Uniswap V4 pool and pays the ETH to the caller.
 * @dev This revision holds only the constructor, owner controls and the per-token route registry.
 *      The harvest flow (Uniswap V4 `unlock` flash accounting) is added in a later story.
 */
contract SYAHarvester is Ownable {
    /// @notice Stored Curve Router NG route that sells one yield token to SYA's reward token
    struct CurveRoute {
        address[11] path; // Interleaved [tokenIn, pool0, token1, pool1, ...], zero-padded
        uint256[5][5] swapParams; // Per-hop [i, j, swap_type, pool_type, n_coins]
        address[5] pools; // Base pools for meta-swaps, else zero
        bool configured; // Distinguishes "unset" from "all zeros"
    }

    /// @notice Uniswap V4 PoolManager used as the flash source and for the USDC→ETH leg
    IPoolManager public immutable poolManager;
    /// @notice StableYieldAccumulator this harvester claims from
    IStableYieldAccumulator public immutable sya;
    /// @notice Curve Router NG that executes the stored routes
    ICurveRouterNG public immutable router;

    /// @dev yield token => route to SYA's reward token
    mapping(address => CurveRoute) private routes;

    /// @dev Native-ETH / reward-token Uniswap V4 pool used for the final swap to ETH
    PoolKey private ethPool;

    /// @notice Emitted when the owner registers or replaces the route for `token`
    event RouteSet(address indexed token);
    /// @notice Emitted when the owner removes the route for `token`
    event RouteCleared(address indexed token);
    /// @notice Emitted when the owner sets the native-ETH / reward-token V4 pool
    event EthPoolSet(
        address indexed currency0, address indexed currency1, uint24 fee, int24 tickSpacing, address hooks
    );

    /// @notice A required address argument was zero
    error ZeroAddress();
    /// @notice `path[0]` of a route does not equal the token it is registered for
    error InvalidRouteStart(address token, address first);
    /// @notice The last non-zero entry of a route's path is not SYA's reward token
    error InvalidRouteEnd(address expected, address last);
    /// @notice The pool key is not a native-ETH / reward-token pool
    error InvalidEthPool();

    /**
     * @param _owner Initial owner allowed to manage routes and the ETH pool
     * @param _poolManager Uniswap V4 PoolManager
     * @param _sya StableYieldAccumulator to claim from
     * @param _router Curve Router NG
     */
    constructor(address _owner, IPoolManager _poolManager, IStableYieldAccumulator _sya, ICurveRouterNG _router)
        Ownable(_owner)
    {
        if (address(_poolManager) == address(0) || address(_sya) == address(0) || address(_router) == address(0)) {
            revert ZeroAddress();
        }
        poolManager = _poolManager;
        sya = _sya;
        router = _router;
    }

    /**
     * @notice Register (or replace) the Curve Router NG route that sells `token` to SYA's reward token
     * @param token Yield token the route sells
     * @param path 11-slot `_route` array for Curve Router NG
     * @param swapParams 5x5 `_swap_params` matrix for Curve Router NG
     * @param pools 5-slot `_pools` array for Curve Router NG
     * @dev Requires `path[0] == token` and that the last non-zero entry of `path` equals
     *      `sya.rewardToken()`, read at call time.
     */
    function setRoute(
        address token,
        address[11] calldata path,
        uint256[5][5] calldata swapParams,
        address[5] calldata pools
    ) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (path[0] != token) revert InvalidRouteStart(token, path[0]);

        address last;
        for (uint256 i = 0; i < 11; i++) {
            if (path[i] != address(0)) {
                last = path[i];
            }
        }
        address rewardToken = sya.rewardToken();
        if (last != rewardToken) revert InvalidRouteEnd(rewardToken, last);

        CurveRoute storage r = routes[token];
        r.path = path;
        r.swapParams = swapParams;
        r.pools = pools;
        r.configured = true;

        emit RouteSet(token);
    }

    /**
     * @notice Remove the route registered for `token`
     * @param token Yield token whose route is removed
     */
    function clearRoute(address token) external onlyOwner {
        delete routes[token];
        emit RouteCleared(token);
    }

    /**
     * @notice Read the route registered for `token`
     * @param token Yield token
     * @return The stored route; `configured` is false if none is registered
     */
    function getRoute(address token) external view returns (CurveRoute memory) {
        return routes[token];
    }

    /**
     * @notice Set the native-ETH / reward-token Uniswap V4 pool used for the final swap to ETH
     * @param key Pool key; `currency0` must be native ETH and `currency1` must be `sya.rewardToken()`
     */
    function setEthPool(PoolKey calldata key) external onlyOwner {
        if (Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != sya.rewardToken()) {
            revert InvalidEthPool();
        }
        ethPool = key;
        emit EthPoolSet(
            Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), key.fee, key.tickSpacing, address(key.hooks)
        );
    }

    /**
     * @notice Read the stored native-ETH / reward-token Uniswap V4 pool key
     * @return The stored pool key (all zero if never set)
     */
    function getEthPool() external view returns (PoolKey memory) {
        return ethPool;
    }
}
