// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
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
contract SYAHarvester is Ownable, ERC1155Holder, IUnlockCallback {
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

    /// @notice Gas charged on top of the gas measured between entry and the profitability check: the
    ///         intrinsic transaction cost, calldata, the ETH payout and everything after the measurement.
    /// @dev Calibrated (story 004) on a mainnet fork at block 26_261_000 (+1h warp), full three-strategy
    ///      harvest with NFT index 1, `vm.txGasPrice` 1 gwei:
    ///      - in-contract estimate `g0 - gasleft()` at the check: 2_720_016 gas (identical in forge and on an
    ///        anvil fork, read back from an `Unprofitable` revert at a huge gas price);
    ///      - real gas before refunds (forge: 21_000 intrinsic + calldata + gas measured around the external
    ///        call): 2_777_404 — gap 57_388, an upper bound (it also charges the test's cold CALL);
    ///      - real anvil receipt `gasUsed` (after EIP-3529 refunds): 2_273_493, i.e. ~0.5M below the estimate.
    ///      Set to the pre-refund gap rounded up: refunds depend on live state and are not counted on, so the
    ///      check stays conservative (it may over-charge by the refund, never under-charge).
    ///      Re-checked by `test/fork/SYAHarvester.fork.t.sol::test_fork_gasOverhead_coversMeasuredGap`.
    uint256 public constant GAS_OVERHEAD = 60_000;

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
    /// @notice The token Curve Router NG would deliver for a route is not SYA's reward token
    /// @dev Router NG executes hop k while `path[2k+1] != 0` and delivers `path[2k]` at the first empty pool
    ///      slot (`path[10]` after five hops); `delivered` is that token, not the path's last non-zero entry.
    error InvalidRouteEnd(address expected, address delivered);
    /// @notice A route has a non-zero entry at `index`, after the prefix Curve Router NG actually executes
    /// @dev Router NG stops at the first empty pool slot, so any later entry is never executed. Such a route
    ///      would deliver an intermediate token and strand it (audit 01, M-01).
    error InvalidRouteGap(uint256 index);
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
    /// @notice The ETH produced does not cover the gas the transaction burns at `tx.gasprice`
    error Unprofitable(uint256 ethOut, uint256 gasCost);

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
     * @dev Validates the route the way Curve Router NG executes it. Router NG runs hop k while the pool slot
     *      `path[2k+1]` is non-zero and delivers `path[2k]` at the first empty pool slot (`path[10]` after five
     *      hops). Requires `path[0] == token`, that no non-zero entry follows that executed prefix
     *      (`InvalidRouteGap`), and that the delivered token equals `sya.rewardToken()`, read at call time
     *      (`InvalidRouteEnd`). A reward-token "route" with `path[1] == 0` is accepted; it is never executed
     *      because `_sellYield` skips the reward token.
     */
    function setRoute(
        address token,
        address[11] calldata path,
        uint256[5][5] calldata swapParams,
        address[5] calldata pools
    ) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (path[0] != token) revert InvalidRouteStart(token, path[0]);

        // Router NG executes hop k while path[2k+1] != 0 and delivers path[2k] at the first empty pool slot.
        uint256 k;
        while (k < 5 && path[2 * k + 1] != address(0)) k++;
        // Nothing may follow the executed prefix: a trailing entry is never executed (empty when k == 5).
        for (uint256 i = 2 * k + 1; i < 11; i++) {
            if (path[i] != address(0)) revert InvalidRouteGap(i);
        }
        address rewardToken = sya.rewardToken();
        address delivered = path[2 * k];
        if (delivered != rewardToken) revert InvalidRouteEnd(rewardToken, delivered);

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
     * @param nftIndex Claim NFT index, passed through to `sya.claim`. `0` means "transfer no NFT".
     * @param minEthOut Minimum ETH the caller accepts. This is the ONLY slippage check: the whole call
     *        is atomic, so per-token minimums add nothing. Routes are executed with zero expected
     *        output and SYA's own `minRewardTokenSupplied` is passed as 0.
     * @return ethOut ETH paid to `msg.sender`
     * @dev Order: gas snapshot, NFT pull, `poolManager.unlock` (see `unlockCallback`), NFT refund,
     *      `minEthOut` check, gas check, ETH payout. Every state change precedes the external ETH call.
     *
     *      Claim NFT. When `nftIndex != 0` and `sya.nftMinter()` (read at call time) is non-zero, one unit
     *      of `nftIndex` is pulled from the caller before the unlock, which needs the caller's
     *      `setApprovalForAll(harvester, true)`; without it the pull reverts. SYA burns the unit from the
     *      harvester as an authorized burner on the NFT minter, so the harvester grants no approval.
     *      After the unlock the harvester's WHOLE balance of `nftIndex` (including any stray units) is
     *      returned to the caller. Today's SYA always burns the unit or reverts, so the refund only
     *      fires once NFT gating is switched off in SYA. Likewise, with today's live SYA,
     *      `nftIndex == 0` reverts `"Invalid index"` and `nftMinter() == address(0)` reverts
     *      `"NFT minter not configured"` inside `claim`: those skip-transfer paths only succeed after
     *      the future yield-accumulator gating-off story lands.
     *
     *      Gas check. Reverts `Unprofitable` if
     *      `ethOut < (gasleft() at entry - gasleft() before payout + GAS_OVERHEAD) * tx.gasprice`.
     *      Simulations run at a zero gas price (most wallet `eth_call`s) pass this check trivially, so
     *      off-chain tooling must simulate with fee fields set.
     *
     *      Nested-unlock hazard: anything called from inside the callback (a strategy's `skimSurplus`,
     *      a route step) that calls `poolManager.unlock` again reverts `AlreadyUnlocked` and fails the
     *      harvest.
     */
    function harvest(address[] calldata exemptStrategies, uint256 nftIndex, uint256 minEthOut)
        external
        returns (uint256 ethOut)
    {
        uint256 g0 = gasleft();
        if (Currency.unwrap(ethPool.currency1) == address(0)) revert EthPoolNotSet();

        address nftAddr = sya.nftMinter();
        bool moveNft = nftIndex != 0 && nftAddr != address(0);
        if (moveNft) {
            IERC1155(nftAddr).safeTransferFrom(msg.sender, address(this), nftIndex, 1, "");
        }

        poolManager.unlock(abi.encode(exemptStrategies, nftIndex));

        if (moveNft) {
            uint256 bal = IERC1155(nftAddr).balanceOf(address(this), nftIndex);
            if (bal != 0) {
                IERC1155(nftAddr).safeTransferFrom(address(this), msg.sender, nftIndex, bal, "");
            }
        }

        ethOut = address(this).balance;
        if (ethOut < minEthOut) revert InsufficientEthOut(ethOut, minEthOut);

        uint256 gasCost = (g0 - gasleft() + GAS_OVERHEAD) * tx.gasprice;
        if (ethOut < gasCost) revert Unprofitable(ethOut, gasCost);

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
