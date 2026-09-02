// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {WeirAuctionBase} from "./WeirAuctionBase.sol";
import {IWeirAuction} from "./interfaces/IWeirAuction.sol";
import {IRebateVault} from "./interfaces/IRebateVault.sol";

/// @title WeirAuction
/// @notice Auctions per-epoch priority execution rights; winning bids fund the LP rebate vault.
/// @dev Bids are plaintext, so every searcher can read every rival's bid before an epoch
///      closes. `WeirSealedAuction` is the CoFHE variant that closes that gap; this one
///      stays as the simpler baseline to measure it against.
contract WeirAuction is IWeirAuction, WeirAuctionBase {
    error BidBelowReserve();
    error EpochAlreadySettled();
    error EpochNotSettled();
    error NothingToRefund();
    error WinnerCannotRefund();
    error ZeroBid();

    struct EpochState {
        address leader;
        uint256 leadingBid;
        bool settled;
    }

    mapping(PoolId => mapping(uint256 => EpochState)) public epochs;

    /// @notice Cumulative amount a bidder has committed to an epoch
    mapping(PoolId => mapping(uint256 => mapping(address => uint256))) public bidOf;

    event BidPlaced(PoolId indexed poolId, uint256 indexed epoch, address indexed bidder, uint256 total);
    event RefundClaimed(PoolId indexed poolId, uint256 indexed epoch, address indexed bidder, uint256 amount);

    constructor(address _governance, IRebateVault _rebateVault) WeirAuctionBase(_governance, _rebateVault) {}

    /// @inheritdoc IWeirAuction
    function winnerOf(PoolId poolId, uint256 epoch) external view override returns (address) {
        return epochs[poolId][epoch].leader;
    }

    /// @notice Places (or tops up) a plaintext bid for the next epoch
    function bid(PoolId poolId) external payable {
        if (msg.value == 0) revert ZeroBid();
        if (startBlock[poolId] == 0) revert EpochNotStarted();

        // Bidding is always for the epoch after the one executing now, so an epoch's
        // leader is already fixed by the time its first swap can land.
        uint256 epoch = currentEpoch(poolId) + 1;

        uint256 total = bidOf[poolId][epoch][msg.sender] + msg.value;
        if (total < reservePrice(poolId)) revert BidBelowReserve();

        bidOf[poolId][epoch][msg.sender] = total;

        EpochState storage state = epochs[poolId][epoch];
        if (total > state.leadingBid) {
            state.leader = msg.sender;
            state.leadingBid = total;
        }

        emit BidPlaced(poolId, epoch, msg.sender, total);
    }

    /// @notice Moves a concluded epoch's winning bid into the rebate vault
    function settleEpoch(PoolId poolId, uint256 epoch) external {
        if (currentEpoch(poolId) < epoch) revert EpochNotStarted();

        EpochState storage state = epochs[poolId][epoch];
        if (state.settled) revert EpochAlreadySettled();
        state.settled = true;

        uint256 amount = state.leadingBid;
        if (amount > 0) {
            rebateVault.depositRebate{value: amount}(poolId);
        }

        emit EpochSettled(poolId, epoch, state.leader, amount);
    }

    /// @notice Refunds a losing bid once its epoch has settled
    function claimRefund(PoolId poolId, uint256 epoch) external returns (uint256 amount) {
        EpochState storage state = epochs[poolId][epoch];
        if (!state.settled) revert EpochNotSettled();
        if (msg.sender == state.leader) revert WinnerCannotRefund();

        amount = bidOf[poolId][epoch][msg.sender];
        if (amount == 0) revert NothingToRefund();

        bidOf[poolId][epoch][msg.sender] = 0;

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit RefundClaimed(poolId, epoch, msg.sender, amount);
    }
}
