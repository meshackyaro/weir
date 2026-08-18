// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @title IWeirAuction
/// @notice Per-block priority execution auction whose proceeds are rebated to LPs
interface IWeirAuction {
    event BidPlaced(PoolId indexed poolId, uint256 indexed epoch, address indexed bidder, uint256 total);
    event EpochSettled(PoolId indexed poolId, uint256 indexed epoch, address winner, uint256 amount);
    event RefundClaimed(PoolId indexed poolId, uint256 indexed epoch, address indexed bidder, uint256 amount);

    /// @notice Epoch currently executing for a pool
    function currentEpoch(PoolId poolId) external view returns (uint256);

    /// @notice Leading bidder for an epoch. Address zero when no bid was placed.
    function winnerOf(PoolId poolId, uint256 epoch) external view returns (address);

    /// @notice Places (or tops up) a bid for the next epoch
    function bid(PoolId poolId) external payable;

    /// @notice Moves a concluded epoch's winning bid into the rebate vault
    function settleEpoch(PoolId poolId, uint256 epoch) external;

    /// @notice Refunds a losing bid once its epoch has settled
    function claimRefund(PoolId poolId, uint256 epoch) external returns (uint256);
}
