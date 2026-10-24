// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HarvesterFixture} from "./utils/HarvesterFixture.sol";

interface IGasOverhead {
    function GAS_OVERHEAD() external view returns (uint256);
}

/// @notice On-chain gas check: `harvest` reverts `Unprofitable(ethOut, gasCost)` when
///         `ethOut < (gasUsedSinceEntry + GAS_OVERHEAD) * tx.gasprice`.
/// @dev `vm.txGasPrice` drives `tx.gasprice`. In this harness one harvest yields ~9e7 wei, so a gas
///      price of a few hundred wei is the break-even point.
contract SYAHarvesterGasTest is HarvesterFixture {
    bytes4 internal constant UNPROFITABLE = bytes4(keccak256("Unprofitable(uint256,uint256)"));

    /// @dev ETH a harvest pays at gas price 0 (state is restored afterwards)
    function _ethOutAtZeroPrice() internal returns (uint256 ethOut) {
        uint256 snap = vm.snapshotState();
        vm.txGasPrice(0);
        vm.prank(keeper);
        ethOut = harvester.harvest(_none(), 0, 0);
        vm.revertToState(snap);
    }

    /// @dev Harvest at `price` without expecting an outcome; returns success and the raw return/revert data
    function _harvestAt(uint256 price) internal returns (bool ok, bytes memory ret) {
        vm.txGasPrice(price);
        vm.prank(keeper);
        (ok, ret) = address(harvester).call(abi.encodeCall(harvester.harvest, (_none(), 0, 0)));
    }

    function _decodeUnprofitable(bytes memory ret) internal pure returns (uint256 ethOut, uint256 gasCost) {
        require(ret.length == 68, "not Unprofitable(uint256,uint256)");
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 0x20))
            ethOut := mload(add(ret, 0x24))
            gasCost := mload(add(ret, 0x44))
        }
        require(sel == UNPROFITABLE, "wrong selector");
    }

    /// @dev Gas units the check charged in an `Unprofitable` revert at `price` (measured + GAS_OVERHEAD)
    function _chargedGasUnits(uint256 price) internal returns (uint256 ethOut, uint256 units) {
        uint256 snap = vm.snapshotState();
        (bool ok, bytes memory ret) = _harvestAt(price);
        vm.revertToState(snap);
        assertFalse(ok, "expected Unprofitable");
        uint256 gasCost;
        (ethOut, gasCost) = _decodeUnprofitable(ret);
        assertEq(gasCost % price, 0, "gasCost is units * tx.gasprice");
        units = gasCost / price;
    }

    function test_gas_costAboveEthOut_revertsUnprofitable() public {
        uint256 expectedEthOut = _ethOutAtZeroPrice();
        uint256 price = 1e6; // ~3e11 wei of gas against ~9e7 wei out

        (bool ok, bytes memory ret) = _harvestAt(price);

        assertFalse(ok, "harvest succeeded");
        (uint256 ethOut, uint256 gasCost) = _decodeUnprofitable(ret);
        assertEq(ethOut, expectedEthOut, "reported ethOut");
        assertGt(gasCost, ethOut, "gasCost exceeds ethOut");
        assertEq(address(harvester).balance, 0, "no ETH left behind");
    }

    function test_gas_zeroGasPrice_passesTrivially() public {
        uint256 before = keeper.balance;
        vm.txGasPrice(0);

        vm.prank(keeper);
        uint256 ethOut = harvester.harvest(_none(), 0, 0);

        assertGt(ethOut, 0, "ethOut");
        assertEq(keeper.balance - before, ethOut, "paid");
        _assertHarvesterEmpty();
    }

    function test_gas_chargedUnits_coverMeasuredWorkPlusOverhead() public {
        uint256 overhead = IGasOverhead(address(harvester)).GAS_OVERHEAD();
        assertGt(overhead, 0, "GAS_OVERHEAD set");

        (, uint256 units) = _chargedGasUnits(1e6);

        // The snapshot is taken at entry, so the measured part spans the whole unlock (claim, route sale,
        // V4 swap and settlement), which costs well over 100k gas in this harness.
        assertGt(units, overhead + 100_000, "measured gas spans the harvest");
        assertLt(units, overhead + 2_000_000, "measured gas is sane");
    }

    function test_gas_borderlinePrice_flipsPassFail() public {
        (uint256 ethOut, uint256 units) = _chargedGasUnits(1e6);
        uint256 breakEven = ethOut / units;
        assertGt(breakEven, 20, "harness gives a usable break-even price");

        uint256 snap = vm.snapshotState();
        (bool okBelow,) = _harvestAt(breakEven * 9 / 10);
        assertTrue(okBelow, "10% below break-even passes");
        vm.revertToState(snap);

        (bool okAbove, bytes memory ret) = _harvestAt(breakEven * 11 / 10);
        assertFalse(okAbove, "10% above break-even fails");
        (uint256 reportedOut, uint256 gasCost) = _decodeUnprofitable(ret);
        assertEq(reportedOut, ethOut, "same ethOut");
        assertGt(gasCost, reportedOut, "gasCost exceeds ethOut");
    }

    function test_gas_minEthOutSatisfied_butUnprofitable_stillReverts() public {
        // The slippage bound and the gas check are independent: meeting minEthOut does not bypass gas
        uint256 expectedEthOut = _ethOutAtZeroPrice();
        vm.txGasPrice(1e6);
        vm.prank(keeper);
        (bool ok, bytes memory ret) =
            address(harvester).call(abi.encodeCall(harvester.harvest, (_none(), 0, expectedEthOut)));
        assertFalse(ok, "harvest succeeded");
        _decodeUnprofitable(ret);
    }
}
