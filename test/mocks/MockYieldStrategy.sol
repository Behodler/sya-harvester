// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Minimal yield strategy stand-in for unit tests.
/// @dev Holds `token` and a settable `surplus`. `skimSurplus` pushes the surplus to the recipient,
///      mirroring vault `AYieldStrategy.skimSurplus` (which is `whenNotPaused`). An optional "nest"
///      mode calls `poolManager.unlock` from inside `skimSurplus` to reproduce the nested-unlock hazard.
contract MockYieldStrategy {
    using SafeERC20 for IERC20;

    error StrategyPaused();
    error WrongToken();

    address public immutable token;
    uint256 public surplus;
    bool public paused;
    IPoolManager public nestPoolManager;

    constructor(address _token) {
        token = _token;
    }

    /// @notice Set the surplus; the caller must ensure this contract holds at least that much `token`
    function setSurplus(uint256 _surplus) external {
        surplus = _surplus;
    }

    function setPaused(bool _paused) external {
        paused = _paused;
    }

    /// @notice When set, `skimSurplus` calls `pm.unlock` (reverts `AlreadyUnlocked` inside a callback)
    function setNestPoolManager(IPoolManager pm) external {
        nestPoolManager = pm;
    }

    function skimSurplus(address _token, address recipient) external returns (uint256 amount) {
        if (paused) revert StrategyPaused();
        if (_token != token) revert WrongToken();
        if (address(nestPoolManager) != address(0)) {
            nestPoolManager.unlock("");
        }
        amount = surplus;
        surplus = 0;
        if (amount > 0) {
            IERC20(token).safeTransfer(recipient, amount);
        }
    }
}
