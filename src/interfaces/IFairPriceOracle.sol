// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @title IFairPriceOracle
/// @notice Reference price used to floor auction bids and to check executions after the fact
interface IFairPriceOracle {
    event FeedRegistered(PoolId indexed poolId, address feed, uint256 staleAfter);

    /// @notice Latest fair price for a pool, normalised to 18 decimals
    /// @dev Reverts when no feed is registered or the feed data is stale
    function fairPrice(PoolId poolId) external view returns (uint256);

    /// @notice Whether a feed is registered for the pool
    function hasFeed(PoolId poolId) external view returns (bool);
}
