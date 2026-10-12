// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { ChainlinkOracle } from "../src/oracle/ChainlinkOracle.sol";
import { IAggregatorV3 } from "../src/interfaces/IAggregatorV3.sol";
import { IMarketCalendar } from "../src/interfaces/IMarketCalendar.sol";

/// @notice Deploy the same adapter used locally, pointing at explicitly selected live/testnet feed proxies.
contract DeployChainlinkOracle is Script {
    /// @notice Deploys an adapter using the explicit feed and session environment configuration.
    /// @return oracle Adapter bound to these immutable price inputs and validity limits.
    function run() external returns (ChainlinkOracle oracle) {
        ChainlinkOracle.FeedConfig memory asset = _config("ASSET");
        ChainlinkOracle.FeedConfig memory quote = _config("QUOTE");
        address calendar =
            vm.envOr("ENFORCE_MARKET_HOURS", false) ? vm.envAddress("MARKET_CALENDAR") : address(0);
        address sequencer = vm.envAddress("SEQUENCER_FEED");
        uint256 grace = vm.envUint("SEQUENCER_GRACE_PERIOD");
        bool isL2 = vm.envBool("IS_L2");
        require(!isL2 || sequencer != address(0), "L2 requires sequencer feed");
        require(grace <= type(uint32).max, "Grace period overflow");
        vm.startBroadcast();
        oracle = new ChainlinkOracle(
            asset, quote, IMarketCalendar(calendar), IAggregatorV3(sequencer), uint32(grace)
        );
        vm.stopBroadcast();
        console2.log("ChainlinkOracle:", address(oracle));
    }

    function _config(string memory prefix) private view returns (ChainlinkOracle.FeedConfig memory config) {
        uint256 maxAge = vm.envUint(string.concat(prefix, "_MAX_AGE"));
        uint256 minimum = vm.envUint(string.concat(prefix, "_MIN_PRICE"));
        uint256 maximum = vm.envUint(string.concat(prefix, "_MAX_PRICE"));
        require(
            maxAge <= type(uint32).max && minimum <= type(uint128).max && maximum <= type(uint128).max,
            "Configuration overflow"
        );
        config = ChainlinkOracle.FeedConfig({
            feed: IAggregatorV3(vm.envAddress(string.concat(prefix, "_USD_FEED"))),
            maxAge: uint32(maxAge),
            minPrice: uint128(minimum),
            maxPrice: uint128(maximum)
        });
    }
}
