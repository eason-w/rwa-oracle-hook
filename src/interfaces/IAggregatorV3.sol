// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal read surface of Chainlink's AggregatorV3Interface.
/// @dev Kept ABI-compatible with deployed feed proxies; this interface does not implement a feed.
interface IAggregatorV3 {
    /// @notice Returns the number of decimals in a price answer.
    /// @return scale Decimal places used by latestRoundData().answer.
    function decimals() external view returns (uint8 scale);

    /// @notice Returns the feed's human-readable description.
    /// @return label Provider-supplied name; not sufficient evidence of token/feed compatibility.
    function description() external view returns (string memory label);

    /// @notice Returns the latest available round; the caller must validate it before use.
    /// @return roundId Provider's round identifier, including proxy phase where applicable.
    /// @return answer Signed price answer, or status code for an uptime feed.
    /// @return startedAt Unix timestamp when the round or uptime transition started.
    /// @return updatedAt Unix timestamp when the answer was updated.
    /// @return answeredInRound Round in which the answer was computed; retained for ABI compatibility.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
