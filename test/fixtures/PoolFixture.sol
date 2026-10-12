// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import { RwaOracleHook } from "../../src/RwaOracleHook.sol";
import { MockPriceOracle } from "../mocks/MockPriceOracle.sol";
import { MockToken } from "../mocks/MockToken.sol";
import { PoolRouter } from "../helpers/PoolRouter.sol";

abstract contract PoolFixture is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    PoolManager internal manager;
    RwaOracleHook internal hook;
    MockPriceOracle internal oracle;
    MockToken internal asset;
    MockToken internal quote;
    PoolRouter internal router;
    PoolKey internal key;
    uint128 internal constant SEED_LIQUIDITY = 12_247_448_713_915_890;

    function _setup(bool reversed) internal {
        vm.warp(1_800_000_000);
        manager = new PoolManager(address(this));
        // Fixed token addresses make both currency orderings reproducible.
        address assetAddress = reversed ? address(0x2000) : address(0x1000);
        address quoteAddress = reversed ? address(0x1000) : address(0x2000);
        deployCodeTo("MockToken.sol", abi.encode("Mock SPY", "SPY", uint8(18)), assetAddress);
        deployCodeTo("MockToken.sol", abi.encode("Mock USD Coin", "USDC", uint8(6)), quoteAddress);
        asset = MockToken(assetAddress);
        quote = MockToken(quoteAddress);
        oracle = new MockPriceOracle(address(this));
        oracle.publish(150e18, true, uint64(block.timestamp + 8 hours));
        RwaOracleHook.Config memory config = _config();
        bytes memory args = abi.encode(manager, oracle, asset, quote, uint8(18), uint8(6), int24(60), config);
        (, bytes32 salt) = HookMiner.find(address(this), 0x2080, type(RwaOracleHook).creationCode, args);
        hook = new RwaOracleHook{ salt: salt }(
            manager, oracle, address(asset), address(quote), 18, 6, 60, config
        );
        key = PoolKey(Currency.wrap(address(0x1000)), Currency.wrap(address(0x2000)), 0x800000, 60, hook);
        manager.initialize(key, _sqrtPrice(150e18));
        router = new PoolRouter(manager, key);
        asset.mint(address(this), 1_000_000e18);
        quote.mint(address(this), 1_000_000_000e6);
        asset.approve(address(router), type(uint256).max);
        quote.approve(address(router), type(uint256).max);
        router.modifyLiquidity(
            int256(uint256(SEED_LIQUIDITY)), type(uint256).max, type(uint256).max, block.timestamp
        );
    }

    function _config() internal pure returns (RwaOracleHook.Config memory) {
        return RwaOracleHook.Config(500, 3000, 300, 500, 300);
    }

    function _sqrtPrice(uint256 price) internal view returns (uint160) {
        uint256 ratio = address(asset) < address(quote)
            ? FullMath.mulDiv(price, 1 << 192, 1e30)
            : FullMath.mulDiv(1e30, 1 << 192, price);
        return uint160(FixedPointMathLib.sqrt(ratio));
    }

    function _buy(uint256 quoteAmount) internal {
        router.swap(address(quote) < address(asset), quoteAmount, 0, block.timestamp);
    }

    function _sell(uint256 assetAmount) internal {
        router.swap(address(asset) < address(quote), assetAmount, 0, block.timestamp);
    }

    function _publish(uint256 price) internal {
        oracle.publish(price, true, uint64(block.timestamp + 8 hours));
    }
}
