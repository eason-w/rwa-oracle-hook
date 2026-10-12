// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IPriceOracle } from "../../src/interfaces/IPriceOracle.sol";
import { OraclePriceMath } from "../../src/libraries/OraclePriceMath.sol";

/// @notice Manually published observations for local experiments. Not a live market feed.
contract MockPriceOracle is IPriceOracle {
    error Unauthorized();
    error InvalidSession();

    address public immutable publisher;
    Observation private observation;

    event ObservationPublished(uint256 price, uint64 updatedAt, uint64 validUntil, bool marketOpen);

    constructor(address publisher_) {
        if (publisher_ == address(0)) revert Unauthorized();
        publisher = publisher_;
    }

    /// @notice Publish a synthetic reference. A session lasts at most one day and cannot outlive its expiry.
    function publish(uint256 price, bool marketOpen, uint64 validUntil) external {
        if (msg.sender != publisher) revert Unauthorized();
        OraclePriceMath.validate(price);
        if (validUntil <= block.timestamp || validUntil > block.timestamp + 1 days) revert InvalidSession();
        observation = Observation(price, uint64(block.timestamp), validUntil, marketOpen);
        emit ObservationPublished(price, uint64(block.timestamp), validUntil, marketOpen);
    }

    function latestObservation() external view returns (Observation memory) {
        return observation;
    }
}
