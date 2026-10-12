// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import { RwaOracleHook } from "../src/RwaOracleHook.sol";
import { ChainlinkOracle } from "../src/oracle/ChainlinkOracle.sol";
import { IPriceOracle } from "../src/interfaces/IPriceOracle.sol";

interface ITokenMetadata {
    /// @notice Whole-token decimal precision.
    function decimals() external view returns (uint8);
}

/// @notice Deploy only the immutable hook against explicitly selected chain infrastructure.
contract DeployRwaHook is Script {
    /// @notice Mines and deploys the hook using the selected manager, adapter and ERC20 metadata.
    /// @return hook Newly deployed hook; its fee policy is immutable.
    function run() external returns (RwaOracleHook hook) {
        address manager = vm.envAddress("POOL_MANAGER");
        address oracle = vm.envAddress("PRICE_ORACLE");
        address asset = vm.envAddress("ASSET");
        address quote = vm.envAddress("QUOTE");
        require(manager.code.length != 0 && oracle.code.length != 0, "Missing manager or oracle");
        uint256 assetAge = ChainlinkOracle(oracle).assetMaxAge();
        uint256 quoteAge = ChainlinkOracle(oracle).quoteMaxAge();
        uint256 maxAge = assetAge > quoteAge ? assetAge : quoteAge;
        require(CREATE2_FACTORY.code.length != 0, "Missing CREATE2 factory");
        require(maxAge > 0 && maxAge <= type(uint32).max, "Invalid oracle age");
        uint8 assetDecimals = ITokenMetadata(asset).decimals();
        uint8 quoteDecimals = ITokenMetadata(quote).decimals();
        RwaOracleHook.Config memory config = RwaOracleHook.Config({
            baseFee: 500, maxFee: 3000, decaySeconds: 300, initialBandBps: 500, maxOracleAge: uint32(maxAge)
        });
        bytes memory args =
            abi.encode(manager, oracle, asset, quote, assetDecimals, quoteDecimals, int24(60), config);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, 0x2080, type(RwaOracleHook).creationCode, args);
        vm.startBroadcast();
        hook = new RwaOracleHook{ salt: salt }(
            IPoolManager(manager),
            IPriceOracle(oracle),
            asset,
            quote,
            assetDecimals,
            quoteDecimals,
            60,
            config
        );
        vm.stopBroadcast();
        require(address(hook) == expected, "Unexpected hook address");
        console2.log("RwaOracleHook:", address(hook));
    }
}
