// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title ICurveRouterNG
 * @notice Minimal Solidity interface for the Curve Router NG contract
 * @dev Mirrors the Vyper `exchange` signature of the latest Curve Router:
 *      https://etherscan.io/address/0x16C6521Dff6baB339122a0FE25a9116693265353
 *
 *      The router walks a route of up to 5 hops, where each hop is described by a
 *      5-tuple in `_swap_params`: [i, j, swap_type, pool_type, n_coins].
 *      The 11-slot `_route` array interleaves tokens and pools:
 *        [tokenIn, pool0, token1, pool1, token2, ..., tokenOut, 0x0, ...]
 *      padded to 11 slots with zero addresses.
 */
interface ICurveRouterNG {
    /**
     * @notice Perform a multi-hop swap through Curve pools
     * @param _route Alternating token/pool addresses, padded to 11 slots with `address(0)`
     * @param _swap_params Per-hop params `[i, j, swap_type, pool_type, n_coins]` (up to 5 hops)
     * @param _amount Exact amount of input token to swap
     * @param _expected Minimum acceptable amount of output token (slippage protection)
     * @param _pools Optional base pools for meta-swaps (5 slots, unused slots set to zero)
     * @param _receiver Address that will receive the output tokens
     * @return Amount of output tokens delivered to `_receiver`
     */
    function exchange(
        address[11] calldata _route,
        uint256[5][5] calldata _swap_params,
        uint256 _amount,
        uint256 _expected,
        address[5] calldata _pools,
        address _receiver
    ) external payable returns (uint256);
}
