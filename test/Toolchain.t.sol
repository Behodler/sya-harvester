// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";

/// @notice Smoke test proving the toolchain (solc 0.8.26, cancun, remappings, solmate) can deploy a
///         fresh Uniswap V4 PoolManager and its test routers before story 002 builds on them.
contract ToolchainTest is Deployers {
    function setUp() public {
        deployFreshManagerAndRouters();
    }

    function test_deployFreshManagerAndRouters_deploysManager() public view {
        assertGt(address(manager).code.length, 0, "PoolManager not deployed");
        assertGt(address(swapRouter).code.length, 0, "swap router not deployed");
    }
}
