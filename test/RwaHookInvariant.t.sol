// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { PoolFixture } from "./fixtures/PoolFixture.sol";
import { RwaOracleHook } from "../src/RwaOracleHook.sol";
import { MockPriceOracle } from "./mocks/MockPriceOracle.sol";
import { PoolRouter } from "./helpers/PoolRouter.sol";
import { MockToken } from "./mocks/MockToken.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

contract MarketHandler is Test {
    RwaOracleHook private hook;
    MockPriceOracle private oracle;
    PoolRouter private router;
    PoolKey private key;
    bool public invalidTransition;
    uint256 public successfulTrades;

    constructor(RwaOracleHook hook_, MockPriceOracle oracle_, PoolRouter router_, PoolKey memory key_) {
        hook = hook_;
        oracle = oracle_;
        router = router_;
        key = key_;
        MockToken(hook.asset()).mint(address(this), 1_000_000e18);
        MockToken(hook.quote()).mint(address(this), 1_000_000_000e6);
        MockToken(hook.asset()).approve(address(router), type(uint256).max);
        MockToken(hook.quote()).approve(address(router), type(uint256).max);
    }

    function updateReference(uint96 price, bool open) external {
        vm.prank(oracle.publisher());
        oracle.publish(bound(price, 100e18, 200e18), open, uint64(block.timestamp + 8 hours));
    }

    function passTime(uint16 secondsElapsed) external {
        vm.warp(block.timestamp + bound(secondsElapsed, 1, 400));
        vm.roll(block.number + 1);
    }

    function refreshFees() external {
        hook.refreshFees();
        (uint128 referencePrice, uint64 startedAt, int8 side) = hook.auction();
        if (referencePrice != 0 && (startedAt > block.timestamp || side < -1 || side > 1)) {
            invalidTransition = true;
        }
    }

    function trade(uint96 amount, bool buy) external {
        uint256 amountIn = buy ? bound(amount, 1e6, 20_000e6) : bound(amount, 1e16, 100e18);
        bool direction = buy ? !hook.assetIsCurrency0() : hook.assetIsCurrency0();
        try router.swap(direction, amountIn, 0, block.timestamp) {
            successfulTrades++;
            (uint24 buyFee,,,) = hook.previewFee(key, !hook.assetIsCurrency0());
            (uint24 sellFee,,,) = hook.previewFee(key, hook.assetIsCurrency0());
            if (buyFee > hook.maxFee() || sellFee > hook.maxFee()) invalidTransition = true;
        } catch {
            // These bounded trades have ample balances and liquidity; any revert is unexpected.
            invalidTransition = true;
        }
    }
}

contract RwaHookInvariantTest is StdInvariant, PoolFixture {
    MarketHandler private handler;

    function setUp() public {
        _setup(false);
        handler = new MarketHandler(hook, oracle, router, key);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.updateReference.selector;
        selectors[2] = handler.passTime.selector;
        selectors[3] = handler.refreshFees.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_ExecutionPolicySurvivesMarketSequences() public view {
        assertFalse(handler.invalidTransition());
    }

    function invariant_HookHasNoCustodyAndPositionsRemainOwned() public view {
        assertEq(asset.balanceOf(address(hook)), 0);
        assertEq(quote.balanceOf(address(hook)), 0);
        assertEq(router.liquidityOf(address(this)), SEED_LIQUIDITY);
    }

    function invariant_LiquidityCanAlwaysExit() public {
        uint256 snapshotId = vm.snapshotState();
        router.modifyLiquidity(-int256(uint256(SEED_LIQUIDITY)), 0, 0, block.timestamp);
        assertEq(router.liquidityOf(address(this)), 0);
        assertTrue(vm.revertToState(snapshotId));
    }
}
