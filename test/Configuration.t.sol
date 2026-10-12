// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { RwaOracleHook } from "../src/RwaOracleHook.sol";
import { BaseHook } from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPriceOracle } from "../src/interfaces/IPriceOracle.sol";

/// @dev Only constructor validation uses this harness; integration tests use mined production bytecode.
contract ConfigurationHarness is RwaOracleHook {
    constructor(Config memory config, uint8 assetDecimals)
        RwaOracleHook(
            IPoolManager(address(1)),
            IPriceOracle(address(2)),
            address(3),
            address(4),
            assetDecimals,
            6,
            60,
            config
        )
    { }

    function validateHookAddress(BaseHook) internal pure override { }
}

contract ConfigurationTest is Test {
    function test_RejectsInvalidInitializationBand() public {
        RwaOracleHook.Config memory config = _defaults();
        config.initialBandBps = 0;
        _reject(config);
    }

    function test_RejectsUnboundedFees() public {
        RwaOracleHook.Config memory config = _defaults();
        config.maxFee = 100_001;
        _reject(config);
        config = _defaults();
        config.baseFee = config.maxFee + 1;
        _reject(config);
    }

    function test_RejectsInvalidDecayDuration() public {
        RwaOracleHook.Config memory config = _defaults();
        config.decaySeconds = 0;
        _reject(config);
        config = _defaults();
        config.decaySeconds = 3601;
        _reject(config);
    }

    function test_RejectsZeroAgeAndUnsupportedDecimals() public {
        RwaOracleHook.Config memory config = _defaults();
        config.maxOracleAge = 0;
        _reject(config);
        config = _defaults();
        vm.expectRevert(RwaOracleHook.InvalidConfig.selector);
        new ConfigurationHarness(config, 19);
    }

    function _reject(RwaOracleHook.Config memory config) private {
        vm.expectRevert(RwaOracleHook.InvalidConfig.selector);
        new ConfigurationHarness(config, 18);
    }

    function _defaults() private pure returns (RwaOracleHook.Config memory) {
        return RwaOracleHook.Config(500, 3000, 300, 500, 300);
    }
}
