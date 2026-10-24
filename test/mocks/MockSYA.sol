// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal StableYieldAccumulator stand-in for unit tests.
/// @dev Story 001 only needs a settable `rewardToken()`. Later stories extend this mock with
///      claim, strategy and NFT behaviour.
contract MockSYA {
    address public rewardToken;

    constructor(address _rewardToken) {
        rewardToken = _rewardToken;
    }

    function setRewardToken(address _rewardToken) external {
        rewardToken = _rewardToken;
    }
}
