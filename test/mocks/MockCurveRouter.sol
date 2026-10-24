// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Curve Router NG stand-in for unit tests.
/// @dev `exchange` pulls `_amount` of `_route[0]` from the caller and pays
///      `_amount * rate[_route[0]] / 1e18` of the route's last non-zero token to `_receiver`.
///      Pre-fund it with the output token.
contract MockCurveRouter {
    using SafeERC20 for IERC20;

    error Slippage(uint256 out, uint256 expected);

    /// @dev tokenIn => output units per 1e18 input units
    mapping(address => uint256) public rate;
    /// @dev tokenIn => number of `exchange` calls
    mapping(address => uint256) public calls;

    function setRate(address tokenIn, uint256 _rate) external {
        rate[tokenIn] = _rate;
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
        address tokenOut;
        for (uint256 i = 0; i < 11; i++) {
            if (_route[i] != address(0)) tokenOut = _route[i];
        }
        calls[tokenIn]++;
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), _amount);
        out = _amount * rate[tokenIn] / 1e18;
        if (out < _expected) revert Slippage(out, _expected);
        IERC20(tokenOut).safeTransfer(_receiver, out);
    }
}
