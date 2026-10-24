// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

interface IMockNFTMinter {
    function burn(address from, uint256 id, uint256 amount) external;
}

interface IMockStrategy {
    function surplus() external view returns (uint256);
    function skimSurplus(address token, address recipient) external returns (uint256);
}

/// @notice StableYieldAccumulator stand-in for unit tests.
/// @dev Reproduces the real `claim` (StableYieldAccumulator.sol:560-649) ordering and pricing:
///      validate exempt entries, skip zero-token / paused-token / exempt strategies, PUSH yield via
///      `skimSurplus` first, charge on the ACTUAL delivered amount (normalised to 18 decimals)
///      x (10000 - discountRate) / 10000, then PULL the payment with `safeTransferFrom`.
///      NFT handling has two modes:
///      - `Ignore` (default, post-gating-off behaviour): `nftIndex` is left untouched.
///      - `Burn` (live behaviour, StableYieldAccumulator.sol:657-666): requires a configured minter
///        and `nftIndex > 0`, then burns one unit of `nftIndex` from `msg.sender` as an authorized
///        burner, else reverts `NoValidNFT`.
contract MockSYA {
    using SafeERC20 for IERC20;

    error ExemptStrategyNotRegistered();
    error ZeroAmount();
    error InsufficientYield();
    error NoValidNFT();

    enum NftMode {
        Ignore,
        Burn
    }

    NftMode public nftMode;
    /// @dev `msg.sender`'s balance of `nftIndex` observed inside the last `claim` (Ignore mode, minter set)
    uint256 public nftBalanceSeenInClaim;

    address public rewardToken;
    address public nftMinter;
    uint256 public discountRate = 1000; // 10%
    /// @dev Extra bps added to calculateClaimAmount to mimic the live ~10% over-estimate
    uint256 public overEstimateBps;

    address[] internal yieldStrategies;
    mapping(address => address) public strategyTokens;
    mapping(address => bool) public isRegisteredStrategy;
    mapping(address => bool) public tokenPaused;

    uint256 public totalCollected;

    constructor(address _rewardToken) {
        rewardToken = _rewardToken;
    }

    function setRewardToken(address _rewardToken) external {
        rewardToken = _rewardToken;
    }

    function setNFTMinter(address _nftMinter) external {
        nftMinter = _nftMinter;
    }

    function setNftMode(NftMode mode) external {
        nftMode = mode;
    }

    function setDiscountRate(uint256 rate) external {
        discountRate = rate;
    }

    function setOverEstimateBps(uint256 bps) external {
        overEstimateBps = bps;
    }

    function addYieldStrategy(address strategy, address token) external {
        yieldStrategies.push(strategy);
        strategyTokens[strategy] = token;
        isRegisteredStrategy[strategy] = true;
    }

    function pauseToken(address token) external {
        tokenPaused[token] = true;
    }

    function getYieldStrategies() external view returns (address[] memory) {
        return yieldStrategies;
    }

    function claim(uint256 nftIndex, uint256 minRewardTokenSupplied, address[] calldata exemptStrategies) external {
        if (nftMode == NftMode.Burn) {
            require(nftMinter != address(0), "NFT minter not configured");
            require(nftIndex > 0, "Invalid index");
            if (IERC1155(nftMinter).balanceOf(msg.sender, nftIndex) == 0) revert NoValidNFT();
            IMockNFTMinter(nftMinter).burn(msg.sender, nftIndex, 1);
        } else if (nftMinter != address(0) && nftIndex != 0) {
            nftBalanceSeenInClaim = IERC1155(nftMinter).balanceOf(msg.sender, nftIndex);
        }

        _validateExempt(exemptStrategies);

        uint256 totalNormalizedYield;
        for (uint256 i = 0; i < yieldStrategies.length; i++) {
            address strategy = yieldStrategies[i];
            address token = strategyTokens[strategy];
            if (_skip(strategy, token, exemptStrategies)) continue;
            uint256 received = IMockStrategy(strategy).skimSurplus(token, msg.sender);
            if (received > 0) totalNormalizedYield += _normalize(received, token);
        }
        if (totalNormalizedYield == 0) revert ZeroAmount();

        uint256 payment = _denormalize(totalNormalizedYield * (10000 - discountRate) / 10000, rewardToken);
        if (payment < minRewardTokenSupplied) revert InsufficientYield();

        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), payment);
        totalCollected += payment;
    }

    function calculateClaimAmount(address[] calldata exemptStrategies) external view returns (uint256) {
        _validateExempt(exemptStrategies);

        uint256 totalNormalizedYield;
        for (uint256 i = 0; i < yieldStrategies.length; i++) {
            address strategy = yieldStrategies[i];
            address token = strategyTokens[strategy];
            if (_skip(strategy, token, exemptStrategies)) continue;
            uint256 y = IMockStrategy(strategy).surplus();
            if (y > 0) totalNormalizedYield += _normalize(y, token);
        }
        if (totalNormalizedYield == 0) return 0;
        uint256 payment = _denormalize(totalNormalizedYield * (10000 - discountRate) / 10000, rewardToken);
        return payment * (10000 + overEstimateBps) / 10000;
    }

    function _validateExempt(address[] calldata exemptStrategies) internal view {
        for (uint256 i = 0; i < exemptStrategies.length; i++) {
            if (!isRegisteredStrategy[exemptStrategies[i]]) revert ExemptStrategyNotRegistered();
        }
    }

    function _skip(address strategy, address token, address[] calldata exemptStrategies) internal view returns (bool) {
        if (token == address(0)) return true;
        if (tokenPaused[token]) return true;
        for (uint256 j = 0; j < exemptStrategies.length; j++) {
            if (exemptStrategies[j] == strategy) return true;
        }
        return false;
    }

    function _normalize(uint256 amount, address token) internal view returns (uint256) {
        uint8 d = IERC20Metadata(token).decimals();
        return d <= 18 ? amount * 10 ** (18 - d) : amount / 10 ** (d - 18);
    }

    function _denormalize(uint256 amount, address token) internal view returns (uint256) {
        uint8 d = IERC20Metadata(token).decimals();
        return d <= 18 ? amount / 10 ** (18 - d) : amount * 10 ** (d - 18);
    }
}
