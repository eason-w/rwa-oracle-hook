// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { OracleFixture } from "./fixtures/OracleFixture.sol";
import { PositionManager } from "@uniswap/v4-periphery/src/PositionManager.sol";
import { V4Quoter } from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import { IV4Quoter } from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import { IV4Router } from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import { IPositionDescriptor } from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import { IWETH9 } from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { MockV4Router } from "@uniswap/v4-periphery/test/mocks/MockV4Router.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @notice Exercises official periphery implementations against the actual two-feed adapter.
/// @dev V4Router is exercised through its upstream execution harness. This is not a UniversalRouter
///      deployment test. Descriptor/native-token paths are unused for this ERC20-only pair.
contract PeripheryIntegrationTest is OracleFixture, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PositionManager internal positions;
    V4Quoter internal quoter;
    MockV4Router internal swaps;
    IAllowanceTransfer internal permit2;

    function setUp() public virtual {
        _setupPeriphery(false);
    }

    function _setupPeriphery(bool reversed) internal {
        _setupOracle(reversed);
        // Upstream helper installs the pinned 0.8.17 Permit2 bytecode without recompiling it.
        permit2 = IAllowanceTransfer(deployPermit2());
        positions = new PositionManager(
            manager,
            IAllowanceTransfer(address(permit2)),
            100_000,
            IPositionDescriptor(address(0)),
            IWETH9(address(0))
        );
        quoter = new V4Quoter(manager);
        swaps = new MockV4Router(manager);
        asset.approve(address(permit2), type(uint256).max);
        quote.approve(address(permit2), type(uint256).max);
        permit2.approve(address(asset), address(positions), type(uint160).max, type(uint48).max);
        permit2.approve(address(quote), address(positions), type(uint160).max, type(uint48).max);
        asset.approve(address(swaps), type(uint256).max);
        quote.approve(address(swaps), type(uint256).max);
    }

    function test_QuoterMatchesExactInputExecutionWithoutChangingPoolState() public {
        assetFeed.publish(153e8);
        uint256 priceBefore = hook.getPoolPrice(key);
        (uint256 expected, uint256 estimate) = quoter.quoteExactInputSingle(_quoteParams(100e6));
        assertEq(hook.getPoolPrice(key), priceBefore, "quote must roll back the swap");
        assertGt(estimate, 0);
        uint256 beforeBalance = asset.balanceOf(address(this));
        _swapExactInput(100e6, uint128(expected));
        assertEq(asset.balanceOf(address(this)) - beforeBalance, expected);
    }

    function test_QuoterMatchesExactOutputExecution() public {
        assetFeed.publish(153e8);
        (uint256 expected,) = quoter.quoteExactOutputSingle(_quoteParams(1e18));
        uint256 beforeAsset = asset.balanceOf(address(this));
        uint256 beforeQuote = quote.balanceOf(address(this));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: key,
                zeroForOne: address(quote) < address(asset),
                amountOut: 1e18,
                amountInMaximum: uint128(expected),
                hookData: ""
            })
        );
        params[1] = abi.encode(address(quote), expected);
        params[2] = abi.encode(address(asset), uint256(1e18));
        swaps.executeActions(
            abi.encode(
                abi.encodePacked(
                    uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
                ),
                params
            )
        );
        assertEq(asset.balanceOf(address(this)) - beforeAsset, 1e18);
        assertEq(beforeQuote - quote.balanceOf(address(this)), expected);
    }

    function test_QuoterMatchesFallbackExecution() public {
        assetFeed.publish(0);
        (uint256 expected,) = quoter.quoteExactInputSingle(_quoteParams(100e6));
        uint256 beforeBalance = asset.balanceOf(address(this));
        _swapExactInput(100e6, uint128(expected));
        assertEq(asset.balanceOf(address(this)) - beforeBalance, expected);
    }

    function test_MultipleSwapsInOneUnlockUseBlockQuote() public {
        bytes[] memory params = new bytes[](4);
        bytes memory swapParams = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: address(quote) < address(asset),
                amountIn: 100e6,
                amountOutMinimum: 0,
                hookData: ""
            })
        );
        params[0] = swapParams;
        params[1] = swapParams;
        params[2] = abi.encode(address(quote), uint256(200e6));
        params[3] = abi.encode(address(asset), uint256(0));
        uint256 balanceBefore = asset.balanceOf(address(this));
        swaps.executeActions(
            abi.encode(
                abi.encodePacked(
                    uint8(Actions.SWAP_EXACT_IN_SINGLE),
                    uint8(Actions.SWAP_EXACT_IN_SINGLE),
                    uint8(Actions.SETTLE_ALL),
                    uint8(Actions.TAKE_ALL)
                ),
                params
            )
        );
        assertGt(asset.balanceOf(address(this)), balanceBefore);
        (uint256 nextQuote,) = quoter.quoteExactInputSingle(_quoteParams(100e6));
        _swapExactInput(100e6, uint128(nextQuote));
    }

    function test_PositionManagerMintCollectAndBurnWithRejectedOracle() public {
        uint256 id = _mintPosition(SEED_LIQUIDITY);
        assertEq(positions.ownerOf(id), address(this));
        assertEq(positions.getPositionLiquidity(id), SEED_LIQUIDITY);
        _swapExactInput(100e6, 0);
        assetFeed.publish(0);
        uint256 quoteBefore = quote.balanceOf(address(this));
        _positionAction(
            Actions.DECREASE_LIQUIDITY, abi.encode(id, uint256(0), uint128(0), uint128(0), bytes(""))
        );
        assertGt(quote.balanceOf(address(this)), quoteBefore, "LP fees are collectible while closed");
        uint256 assetBefore = asset.balanceOf(address(this));
        _positionAction(Actions.BURN_POSITION, abi.encode(id, uint128(0), uint128(0), bytes("")));
        assertGt(asset.balanceOf(address(this)), assetBefore);
        assertEq(positions.balanceOf(address(this)), 0);
    }

    function test_PositionManagerAllowsNftOwnerToExitAfterTransfer() public {
        uint256 id = _mintPosition(SEED_LIQUIDITY);
        address recipient = makeAddr("position recipient");
        positions.transferFrom(address(this), recipient, id);
        quoteFeed.publish(0);
        vm.prank(recipient);
        _positionAction(Actions.BURN_POSITION, abi.encode(id, uint128(0), uint128(0), bytes("")), recipient);
        assertGt(asset.balanceOf(recipient), 0);
        assertGt(quote.balanceOf(recipient), 0);
    }

    function test_ConcentratedPositionCanCrossTicksAndWithdraw() public {
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        int24 center = tick / 60 * 60;
        uint256 id = _mintPosition(SEED_LIQUIDITY / 10, center - 60, center + 60);
        uint256 beforePrice = hook.getPoolPrice(key);
        _swapExactInput(1500e6, 0);
        assertGt(hook.getPoolPrice(key), beforePrice);
        (, int24 finalTick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertTrue(address(quote) < address(asset) ? finalTick < center - 60 : finalTick > center + 60);
        _positionAction(Actions.BURN_POSITION, abi.encode(id, uint128(0), uint128(0), bytes("")));
        assertEq(positions.balanceOf(address(this)), 0);
    }

    function _quoteParams(uint128 amount) internal view returns (IV4Quoter.QuoteExactSingleParams memory) {
        return IV4Quoter.QuoteExactSingleParams({
            poolKey: key, zeroForOne: address(quote) < address(asset), exactAmount: amount, hookData: ""
        });
    }

    function _swapExactInput(uint128 amount, uint128 minimum) internal {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: address(quote) < address(asset),
                amountIn: amount,
                amountOutMinimum: minimum,
                hookData: ""
            })
        );
        params[1] = abi.encode(address(quote), uint256(amount));
        params[2] = abi.encode(address(asset), uint256(minimum));
        swaps.executeActions(
            abi.encode(
                abi.encodePacked(
                    uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
                ),
                params
            )
        );
    }

    function _mintPosition(uint128 liquidity) internal returns (uint256) {
        return _mintPosition(liquidity, TickMath.minUsableTick(60), TickMath.maxUsableTick(60));
    }

    function _mintPosition(uint128 liquidity, int24 lower, int24 upper) internal returns (uint256 id) {
        id = positions.nextTokenId();
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            lower,
            upper,
            uint256(liquidity),
            type(uint128).max,
            type(uint128).max,
            address(this),
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        positions.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)), params),
            block.timestamp
        );
    }

    function _positionAction(uint256 action, bytes memory parameters) internal {
        _positionAction(action, parameters, address(this));
    }

    function _positionAction(uint256 action, bytes memory parameters, address recipient) internal {
        bytes[] memory params = new bytes[](2);
        params[0] = parameters;
        params[1] = abi.encode(key.currency0, key.currency1, recipient);
        positions.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(action), uint8(Actions.TAKE_PAIR)), params), block.timestamp
        );
    }
}

contract ReversedPeripheryIntegrationTest is PeripheryIntegrationTest {
    function setUp() public override {
        _setupPeriphery(true);
    }
}
