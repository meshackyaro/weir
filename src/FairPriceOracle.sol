// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {IFairPriceOracle} from "./interfaces/IFairPriceOracle.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

/// @title FairPriceOracle
/// @notice Chainlink-backed reference price for a pool, normalised to 18 decimals.
/// @dev Used to floor auction reserves and to judge whether a winner's execution stayed
///      within tolerance of fair value.
contract FairPriceOracle is IFairPriceOracle {
    uint256 private constant TARGET_DECIMALS = 18;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    error Unauthorized();
    error InvalidAddress();
    error InvalidStaleness();
    error UnsupportedDecimals();
    error NoFeed();
    error StalePrice();
    error InvalidPrice();

    struct Feed {
        IAggregatorV3 aggregator;
        uint256 staleAfter;
        uint8 decimals;
    }

    address public governance;

    mapping(PoolId => Feed) public feeds;

    event GovernanceTransferred(address indexed oldGovernance, address indexed newGovernance);

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    constructor(address _governance) {
        if (_governance == address(0)) revert InvalidAddress();
        governance = _governance;
    }

    /// @notice Registers the price feed backing a pool
    /// @param staleAfter Seconds after which a feed answer is rejected
    function registerFeed(PoolId poolId, IAggregatorV3 aggregator, uint256 staleAfter) external onlyGovernance {
        if (address(aggregator) == address(0)) revert InvalidAddress();
        if (staleAfter == 0) revert InvalidStaleness();

        uint8 feedDecimals = aggregator.decimals();
        if (feedDecimals > TARGET_DECIMALS) revert UnsupportedDecimals();

        feeds[poolId] = Feed({aggregator: aggregator, staleAfter: staleAfter, decimals: feedDecimals});

        emit FeedRegistered(poolId, address(aggregator), staleAfter);
    }

    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidAddress();
        emit GovernanceTransferred(governance, newGovernance);
        governance = newGovernance;
    }

    /// @inheritdoc IFairPriceOracle
    function hasFeed(PoolId poolId) external view returns (bool) {
        return address(feeds[poolId].aggregator) != address(0);
    }

    /// @inheritdoc IFairPriceOracle
    function fairPrice(PoolId poolId) public view returns (uint256) {
        Feed memory feed = feeds[poolId];
        if (address(feed.aggregator) == address(0)) revert NoFeed();

        (, int256 answer,, uint256 updatedAt,) = feed.aggregator.latestRoundData();

        if (answer <= 0) revert InvalidPrice();
        if (updatedAt == 0 || block.timestamp - updatedAt > feed.staleAfter) revert StalePrice();

        return uint256(answer) * (10 ** (TARGET_DECIMALS - feed.decimals));
    }

    /// @notice Whether an executed price sits within `toleranceBps` of the pool's fair price
    /// @dev The winner of a priority slot is expected to execute near fair value. A breach is
    ///      the signal that more value was extracted than the bid paid for.
    function isWithinTolerance(PoolId poolId, uint256 executedPrice, uint256 toleranceBps)
        external
        view
        returns (bool)
    {
        uint256 fair = fairPrice(poolId);
        uint256 deviation = executedPrice > fair ? executedPrice - fair : fair - executedPrice;
        return (deviation * BPS_DENOMINATOR) <= (fair * toleranceBps);
    }
}
