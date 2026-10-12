// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";

/// @notice Chainlink-compatible test feed with a configurable publisher.
contract MockAggregator is IAggregatorV3 {
    /// @notice Only the configured local publisher may update this test feed.
    error Unauthorized();
    /// @notice Account permitted to publish arbitrary test answers.
    address public immutable publisher;
    /// @inheritdoc IAggregatorV3
    uint8 public immutable decimals;
    /// @inheritdoc IAggregatorV3
    string public description;
    uint80 private _roundId;
    int256 private _answer;
    uint256 private _updatedAt;

    /// @notice Creates a feed double with no initial report.
    /// @param decimals_ Answer decimal precision.
    /// @param description_ Human-readable test-feed name.
    /// @param publisher_ Account allowed to supply test prices.
    constructor(uint8 decimals_, string memory description_, address publisher_) {
        decimals = decimals_;
        description = description_;
        publisher = publisher_;
    }

    /// @notice Publishes a completed round timestamped in the current block.
    /// @dev Zero/negative answers are intentionally allowed to test adapter rejection.
    /// @param answer_ Test value using this feed's decimal scale.
    function publish(int256 answer_) external {
        if (msg.sender != publisher) revert Unauthorized();
        ++_roundId;
        _answer = answer_;
        _updatedAt = block.timestamp;
    }

    /// @inheritdoc IAggregatorV3
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }
}
