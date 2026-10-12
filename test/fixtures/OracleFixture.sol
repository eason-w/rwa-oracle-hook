// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PoolFixture } from "./PoolFixture.sol";
import { RwaOracleHook } from "../../src/RwaOracleHook.sol";
import { ChainlinkOracle } from "../../src/oracle/ChainlinkOracle.sol";
import { MarketCalendar } from "../../src/oracle/MarketCalendar.sol";
import { MockAggregator } from "../mocks/MockAggregator.sol";
import { PoolRouter } from "../helpers/PoolRouter.sol";
import { IMarketCalendar } from "../../src/interfaces/IMarketCalendar.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @dev Full adapter-backed pool fixture shared by integration and periphery tests.
abstract contract OracleFixture is PoolFixture {
    ChainlinkOracle internal adapter;
    MarketCalendar internal calendar;
    MockAggregator internal assetFeed;
    MockAggregator internal quoteFeed;

    function _setupOracle(bool reversed) internal {
        _setup(reversed);
        assetFeed = new MockAggregator(8, "SPY / USD", address(this));
        quoteFeed = new MockAggregator(8, "USDC / USD", address(this));
        assetFeed.publish(150e8);
        quoteFeed.publish(1e8);
        calendar = new MarketCalendar(address(this), address(this));
        MarketCalendar.Session[] memory windows = new MarketCalendar.Session[](1);
        windows[0] =
            MarketCalendar.Session(uint64(block.timestamp), uint64((block.timestamp / 1 days + 1) * 1 days));
        calendar.schedule(windows);
        adapter = new ChainlinkOracle(
            ChainlinkOracle.FeedConfig(assetFeed, 300, 1e18, 10000e18),
            ChainlinkOracle.FeedConfig(quoteFeed, 3600, 0.8e18, 1.2e18),
            IMarketCalendar(address(0)),
            IAggregatorV3(address(0)),
            0
        );
        RwaOracleHook.Config memory config = _config();
        config.maxOracleAge = 3600; // Adapter validates each leg's separate age limit.
        bytes memory args = abi.encode(manager, adapter, asset, quote, uint8(18), uint8(6), int24(60), config);
        (, bytes32 salt) = HookMiner.find(address(this), 0x2080, type(RwaOracleHook).creationCode, args);
        hook = new RwaOracleHook{ salt: salt }(
            manager, adapter, address(asset), address(quote), 18, 6, 60, config
        );
        key.hooks = hook;
        manager.initialize(key, _sqrtPrice(150e18));
        router = new PoolRouter(manager, key);
        asset.approve(address(router), type(uint256).max);
        quote.approve(address(router), type(uint256).max);
        router.modifyLiquidity(
            int256(uint256(SEED_LIQUIDITY)), type(uint256).max, type(uint256).max, block.timestamp
        );
    }
}
