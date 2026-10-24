// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IStableYieldAccumulator} from "stable-yield-accumulator/src/interfaces/IStableYieldAccumulator.sol";
import {ICurveRouterNG} from "./interfaces/ICurveRouterNG.sol";

/**
 * @title SYAHarvester
 * @notice Flash-loan helper that claims from StableYieldAccumulator (SYA), sells the yield tokens it
 *         receives to SYA's reward token along owner-registered Curve Router NG routes, swaps the
 *         surplus to native ETH in a Uniswap V4 pool and pays the ETH to the caller.
 * @dev The whole harvest runs inside one Uniswap V4 `PoolManager.unlock` (free flash accounting).
 *      The contract is public and stateless between calls: all profit goes to `msg.sender`.
 */
contract SYAHarvester is Ownable, IUnlockCallback {
    using SafeERC20 for IERC20;

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

    /// @notice Extra borrow on top of `sya.calculateClaimAmount`, in basis points (1%)
    uint256 public constant BORROW_BUFFER_BPS = 100;

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
    /// @notice A non-exempt strategy delivered `token` but no route is registered for it
    error RouteNotConfigured(address token);
    /// @notice The ETH produced is below the caller's single slippage bound
    error InsufficientEthOut(uint256 ethOut, uint256 minEthOut);
    /// @notice The caller is not the Uniswap V4 PoolManager
    error NotPoolManager();
    /// @notice `harvest` was called before the owner set the native-ETH / reward-token pool
    error EthPoolNotSet();
    /// @notice Paying the ETH out to the caller failed
    error EthTransferFailed();

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
    /*//////////////////////////////////////////////////////////////
                                 HARVEST
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claim from SYA with flash-borrowed reward token, sell the yield and pay the profit in ETH
     * @param exemptStrategies Registered SYA strategies to skip (passed through to `sya.claim`)
     * @param nftIndex Claim NFT index, passed through to `sya.claim` untouched
     * @param minEthOut Minimum ETH the caller accepts. This is the ONLY slippage check: the whole call
     *        is atomic, so per-token minimums add nothing. Routes are executed with zero expected
     *        output and SYA's own `minRewardTokenSupplied` is passed as 0.
     * @return ethOut ETH paid to `msg.sender`
     * @dev Opens a single `poolManager.unlock`; see `unlockCallback` for the flow. Nested-unlock
     *      hazard: anything called from inside the callback (a strategy's `skimSurplus`, a route step)
     *      that calls `poolManager.unlock` again reverts `AlreadyUnlocked` and fails the harvest.
     */
    function harvest(address[] calldata exemptStrategies, uint256 nftIndex, uint256 minEthOut)
        external
        returns (uint256 ethOut)
    {
        if (Currency.unwrap(ethPool.currency1) == address(0)) revert EthPoolNotSet();

        poolManager.unlock(abi.encode(exemptStrategies, nftIndex));

        ethOut = address(this).balance;
        if (ethOut < minEthOut) revert InsufficientEthOut(ethOut, minEthOut);

        (bool ok,) = msg.sender.call{value: ethOut}("");
        if (!ok) revert EthTransferFailed();
    }

    /**
     * @notice Uniswap V4 unlock callback: borrow, claim, sell, swap to ETH, settle
     * @param data `abi.encode(address[] exemptStrategies, uint256 nftIndex)` from `harvest`
     * @return Empty bytes
     * @dev Only the PoolManager may call this; since V4 delivers the callback only to the contract that
     *      called `unlock`, that is the whole access check.
     *
     *      Borrow = `sya.calculateClaimAmount(exempt) * (10000 + BORROW_BUFFER_BPS) / 10000`. On live
     *      strategies `calculateClaimAmount` already over-estimates by ~10% (SYA charges on the amount
     *      actually delivered, after the strategy's set-aside buffer). Over-borrowing is safe and free:
     *      the unused reward token is simply settled back to the PoolManager.
     *
     *      Every non-exempt strategy token that arrives with a non-zero balance must have a route,
     *      except SYA's reward token itself, which needs no swap (route-coverage invariant).
     *
     *      Nested-unlock hazard: code reached from here must never call `poolManager.unlock`; it
     *      reverts `AlreadyUnlocked`.
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address[] memory exempt, uint256 nftIndex) = abi.decode(data, (address[], uint256));

        address reward = sya.rewardToken();
        uint256 owed = sya.calculateClaimAmount(exempt) * (10000 + BORROW_BUFFER_BPS) / 10000;
        poolManager.take(Currency.wrap(reward), address(this), owed);

        IERC20(reward).forceApprove(address(sya), owed);
        sya.claim(nftIndex, 0, exempt);
        IERC20(reward).forceApprove(address(sya), 0);

        _sellYield(exempt, reward);

        // Reverts (arithmetic underflow) when the sale proceeds cannot repay the borrow: intended loud failure
        uint256 surplus = IERC20(reward).balanceOf(address(this)) - owed;
        _swapSurplusAndSettle(reward, owed, surplus);
        return "";
    }

    /// @notice Accept native ETH only from the PoolManager (the `take` of the swap output)
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Sell the harvester's whole balance of every non-exempt strategy token along its stored route
    function _sellYield(address[] memory exempt, address reward) internal {
        address[] memory strategies = sya.getYieldStrategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            if (_contains(exempt, strategies[i])) continue;
            address token = sya.strategyTokens(strategies[i]);
            if (token == address(0) || token == reward) continue;
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance == 0) continue; // nothing delivered, or a shared token already sold
            CurveRoute storage r = routes[token];
            if (!r.configured) revert RouteNotConfigured(token);

            IERC20(token).forceApprove(address(router), balance);
            router.exchange(r.path, r.swapParams, balance, 0, r.pools, address(this));
            IERC20(token).forceApprove(address(router), 0);
        }
    }

    /// @dev Swap `surplus` reward token to ETH (exact input), repay the full reward-token debt, take the ETH
    function _swapSurplusAndSettle(address reward, uint256 owed, uint256 surplus) internal {
        uint256 debt = owed;
        uint256 ethAmount;
        if (surplus > 0) {
            BalanceDelta delta = poolManager.swap(
                ethPool,
                IPoolManager.SwapParams({
                    zeroForOne: false,
                    amountSpecified: -SafeCast.toInt256(surplus),
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            debt += uint256(int256(-delta.amount1()));
            ethAmount = uint256(int256(delta.amount0()));
        }

        Currency rewardCurrency = Currency.wrap(reward);
        poolManager.sync(rewardCurrency);
        IERC20(reward).safeTransfer(address(poolManager), debt);
        poolManager.settle();

        if (ethAmount > 0) {
            poolManager.take(ethPool.currency0, address(this), ethAmount);
        }
    }

    function _contains(address[] memory list, address item) internal pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == item) return true;
        }
        return false;
    }
}
