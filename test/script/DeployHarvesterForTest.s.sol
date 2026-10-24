// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IStableYieldAccumulator} from "stable-yield-accumulator/src/interfaces/IStableYieldAccumulator.sol";

import {SYAHarvester} from "../../src/SYAHarvester.sol";
import {ICurveRouterNG} from "../../src/interfaces/ICurveRouterNG.sol";
import {MainnetAddresses as A} from "../fork/MainnetAddresses.sol";
import {MainnetRoutes} from "../fork/MainnetRoutes.sol";

/// @title DeployHarvesterForTest
/// @notice TEST-ONLY helper for `test/script/harvest_anvil.sh` (story 005). Deploys `SYAHarvester` on an
///         Anvil mainnet fork and registers story 004's discovered routes and native-ETH/USDC V4 pool key.
/// @dev Not a deployment script: mainnet deployment is out of scope and is done by the human. The broadcaster
///      (an unlocked Anvil account, `--unlocked --sender`) becomes the owner, so the test can `clearRoute`.
///      Prints `HARVESTER=<address>` for the shell harness to parse.
contract DeployHarvesterForTest is Script {
    function run() external returns (SYAHarvester harvester) {
        vm.startBroadcast();
        harvester = new SYAHarvester(
            msg.sender, IPoolManager(A.POOL_MANAGER), IStableYieldAccumulator(A.SYA), ICurveRouterNG(A.CURVE_ROUTER_NG)
        );
        MainnetRoutes.configure(harvester);
        vm.stopBroadcast();
        console2.log("HARVESTER=%s", address(harvester));
    }
}
