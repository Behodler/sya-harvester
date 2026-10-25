// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Curve Router NG stand-in for unit tests.
/// @dev `exchange` pulls `_amount` of `_route[0]` from the caller and pays
///      `_amount * rate[_route[0]] / 1e18` of the token Router NG would deliver to `_receiver`.
///      That token is resolved exactly like Router NG v1.1 does it: hop i outputs `_route[2i+2]`, and the
///      walk stops after hop i when `i == 4 || _route[2i+3] == address(0)`. So the delivered token is
///      `_route[2k]` at the first empty pool slot `_route[2k+1]` (or `_route[10]` after five hops), NOT the
///      route's last non-zero entry (audit 01, M-01). Pools and swap params are ignored; pricing is one
///      rate per input token. Pre-fund it with whichever token a route resolves to.
contract MockCurveRouter {
    using SafeERC20 for IERC20;

    error Slippage(uint256 out, uint256 expected);
    /// @dev `_route[1] == address(0)`: no hop to execute
    error NoHop();
    /// @dev The resolved output token is `address(0)`
    error ZeroOutputToken();

    /// @dev tokenIn => output units per 1e18 input units
    mapping(address => uint256) public rate;
    /// @dev tokenIn => number of `exchange` calls
    mapping(address => uint256) public calls;

    function setRate(address tokenIn, uint256 _rate) external {
        rate[tokenIn] = _rate;
    }

    /// @notice Token Router NG delivers for `_route`
    function resolveOutput(address[11] calldata _route) public pure returns (address tokenOut) {
        if (_route[1] == address(0)) revert NoHop();
        for (uint256 i = 0; i < 5; i++) {
            tokenOut = _route[2 * i + 2];
            if (i == 4 || _route[2 * i + 3] == address(0)) break;
        }
        if (tokenOut == address(0)) revert ZeroOutputToken();
    }

    function exchange(
        address[11] calldata _route,
        uint256[5][5] calldata,
        uint256 _amount,
        uint256 _expected,
        address[5] calldata,
        address _receiver
    ) external payable returns (uint256 out) {
        address tokenIn = _route[0];
        address tokenOut = resolveOutput(_route);
        calls[tokenIn]++;
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), _amount);
        out = _amount * rate[tokenIn] / 1e18;
        if (out < _expected) revert Slippage(out, _expected);
        IERC20(tokenOut).safeTransfer(_receiver, out);
    }
}
