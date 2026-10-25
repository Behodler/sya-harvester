// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {MockCurveRouter} from "./MockCurveRouter.sol";

/// @notice The test double must deliver what Curve Router NG delivers (audit 01, M-01): Router NG executes
///         hop i while `_route[2i+1] != 0` and pays out `_route[2i+2]` of the last hop executed, which is
///         `_route[2k]` at the first empty pool slot `_route[2k+1]` (or `_route[10]` after five hops).
contract MockCurveRouterTest is Test {
    MockCurveRouter internal router;

    MockERC20 internal tokenIn;
    MockERC20 internal mid;
    MockERC20 internal mid2;
    MockERC20 internal mid3;
    MockERC20 internal mid4;
    MockERC20 internal tokenOut;

    address internal pool0 = makeAddr("pool0");
    address internal pool1 = makeAddr("pool1");
    address internal receiver = makeAddr("receiver");

    uint256 internal constant AMOUNT = 100e18;

    function setUp() public {
        router = new MockCurveRouter();
        tokenIn = new MockERC20("In", "IN", 18);
        mid = new MockERC20("Mid", "MID", 18);
        mid2 = new MockERC20("Mid2", "MID2", 18);
        mid3 = new MockERC20("Mid3", "MID3", 18);
        mid4 = new MockERC20("Mid4", "MID4", 18);
        tokenOut = new MockERC20("Out", "OUT", 18);

        // Pre-fund the payout side of every token a route could resolve to
        mid.mint(address(router), 1e30);
        mid2.mint(address(router), 1e30);
        mid3.mint(address(router), 1e30);
        mid4.mint(address(router), 1e30);
        tokenOut.mint(address(router), 1e30);

        router.setRate(address(tokenIn), 1e18);
        tokenIn.mint(address(this), 1e30);
        tokenIn.approve(address(router), type(uint256).max);
    }

    /// @dev Valid swap params for the hops Router NG executes on `path` (swap_type 1 = exchange), zero elsewhere
    function _rows(address[11] memory path) internal pure returns (uint256[5][5] memory params) {
        for (uint256 h = 0; h < 5 && path[2 * h + 1] != address(0); h++) {
            params[h] = [uint256(0), 1, 1, 1, 2];
        }
    }

    function _exchange(address[11] memory path) internal returns (uint256) {
        address[5] memory pools;
        return router.exchange(path, _rows(path), AMOUNT, 0, pools, receiver);
    }

    function test_exchange_contiguousRoute_deliversFinalToken() public {
        address[11] memory path;
        path[0] = address(tokenIn);
        path[1] = pool0;
        path[2] = address(mid);
        path[3] = pool1;
        path[4] = address(tokenOut);

        uint256 out = _exchange(path);

        assertEq(out, AMOUNT);
        assertEq(tokenOut.balanceOf(receiver), AMOUNT, "delivered path[4]");
        assertEq(mid.balanceOf(receiver), 0);
        assertEq(router.calls(address(tokenIn)), 1);
        assertEq(tokenIn.balanceOf(address(router)), AMOUNT, "input pulled");
    }

    function test_exchange_gappedRoute_deliversIntermediateToken() public {
        // [in, pool0, mid, 0, ..., 0, out]: Router NG stops at path[3] == 0 and delivers `mid`
        address[11] memory path;
        path[0] = address(tokenIn);
        path[1] = pool0;
        path[2] = address(mid);
        path[10] = address(tokenOut);

        _exchange(path);

        assertEq(mid.balanceOf(receiver), AMOUNT, "delivered path[2], the intermediate");
        assertEq(tokenOut.balanceOf(receiver), 0, "trailing entry is never delivered");
    }

    function test_exchange_gapInMultiHopRoute_deliversPath2k() public {
        // [in, pool0, mid, pool1, mid2, 0, out, 0...]: first empty pool slot is path[5] (k = 2)
        address[11] memory path;
        path[0] = address(tokenIn);
        path[1] = pool0;
        path[2] = address(mid);
        path[3] = pool1;
        path[4] = address(mid2);
        path[6] = address(tokenOut);

        _exchange(path);

        assertEq(mid2.balanceOf(receiver), AMOUNT, "delivered path[4]");
        assertEq(tokenOut.balanceOf(receiver), 0);
    }

    function test_exchange_fiveHopRoute_deliversPath10() public {
        address[11] memory path;
        path[0] = address(tokenIn);
        path[1] = pool0;
        path[2] = address(mid);
        path[3] = pool1;
        path[4] = address(mid2);
        path[5] = pool0;
        path[6] = address(mid3);
        path[7] = pool1;
        path[8] = address(mid4);
        path[9] = pool0;
        path[10] = address(tokenOut);

        _exchange(path);

        assertEq(tokenOut.balanceOf(receiver), AMOUNT, "delivered path[10]");
        assertEq(mid4.balanceOf(receiver), 0);
    }

    function test_exchange_noHop_reverts() public {
        // path[1] == 0: the real router would execute nothing and transfer nothing meaningful
        address[11] memory path;
        path[0] = address(tokenIn);
        path[2] = address(tokenOut);

        vm.expectRevert(abi.encodeWithSignature("NoHop()"));
        _exchange(path);
    }

    function test_exchange_zeroOutputToken_reverts() public {
        // A pool with no output token: Router NG would try to swap into address(0)
        address[11] memory path;
        path[0] = address(tokenIn);
        path[1] = pool0;

        vm.expectRevert(abi.encodeWithSignature("ZeroOutputToken()"));
        _exchange(path);
    }

    function test_exchange_slippage_stillEnforced() public {
        address[11] memory path;
        path[0] = address(tokenIn);
        path[1] = pool0;
        path[2] = address(tokenOut);
        address[5] memory pools;

        vm.expectRevert(abi.encodeWithSelector(MockCurveRouter.Slippage.selector, AMOUNT, AMOUNT + 1));
        router.exchange(path, _rows(path), AMOUNT, AMOUNT + 1, pools, receiver);
    }

    function test_exchange_zeroIntermediateToken_reverts() public {
        // [in, pool0, 0, pool1, out, 0...]: hop 0 would output address(0)
        address[11] memory path;
        path[0] = address(tokenIn);
        path[1] = pool0;
        path[3] = pool1;
        path[4] = address(tokenOut);

        vm.expectRevert(abi.encodeWithSignature("ZeroIntermediateToken()"));
        _exchange(path);
    }

    function test_resolveOutput_zeroIntermediateToken_reverts() public {
        address[11] memory path;
        path[0] = address(tokenIn);
        path[1] = pool0;
        path[2] = address(mid);
        path[3] = pool1;
        path[5] = pool0; // path[4] == 0 inside the executed prefix (k = 3)
        path[6] = address(tokenOut);

        vm.expectRevert(abi.encodeWithSignature("ZeroIntermediateToken()"));
        router.resolveOutput(path);
    }

    function test_exchange_executedRowWithZeroSwapType_reverts() public {
        address[11] memory path;
        path[0] = address(tokenIn);
        path[1] = pool0;
        path[2] = address(mid);
        path[3] = pool1;
        path[4] = address(tokenOut);
        uint256[5][5] memory params = _rows(path);
        params[1][2] = 0;
        address[5] memory pools;

        vm.expectRevert(abi.encodeWithSignature("BadSwapType(uint256)", 1));
        router.exchange(path, params, AMOUNT, 0, pools, receiver);
    }

    function test_exchange_ignoresRowsBeyondExecutedPrefix() public {
        // the real router never reads rows k..4; rejecting them is setRoute's job, not the router's
        address[11] memory path;
        path[0] = address(tokenIn);
        path[1] = pool0;
        path[2] = address(tokenOut);
        uint256[5][5] memory params = _rows(path);
        params[3] = [uint256(7), 7, 7, 7, 7];
        address[5] memory pools;
        pools[4] = pool1;

        router.exchange(path, params, AMOUNT, 0, pools, receiver);
        assertEq(tokenOut.balanceOf(receiver), AMOUNT);
    }
}
