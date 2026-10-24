// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SYAHarvester} from "../../src/SYAHarvester.sol";

/// @title MainnetRoutes
/// @notice Curve Router NG routes and the native-ETH/USDC Uniswap V4 pool key, discovered on the fork.
/// @dev RED stub: nothing discovered yet.
library MainnetRoutes {
    struct Route {
        address token;
        address[11] path;
        uint256[5][5] swapParams;
        address[5] pools;
    }

    function usdeRoute() internal pure returns (Route memory) {
        revert("MainnetRoutes: USDe route not discovered");
    }

    function dolaRoute() internal pure returns (Route memory) {
        revert("MainnetRoutes: DOLA route not discovered");
    }

    function ethPoolKey() internal pure returns (PoolKey memory key) {
        return key;
    }

    function configure(SYAHarvester) internal pure {
        revert("MainnetRoutes: not discovered");
    }
}
