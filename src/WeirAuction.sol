// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {IWeirAuction} from "./interfaces/IWeirAuction.sol";
import {IRebateVault} from "./interfaces/IRebateVault.sol";

/// @title WeirAuction
/// @notice Auctions per-epoch priority execution rights; winning bids fund the LP rebate vault.
/// @dev Phase 1 runs plaintext bids. Phase 2 replaces the bid value with a Fhenix CoFHE
///      ciphertext so competitors cannot observe each other's bids before an epoch closes.
contract WeirAuction is IWeirAuction {
    error Unauthorized();
    error InvalidAddress();
    error InvalidEpochLength();
    error BidBelowReserve();
    error EpochNotStarted();
    error EpochAlreadySettled();
    error EpochNotSettled();
    error NothingToRefund();
    error WinnerCannotRefund();
    error TransferFailed();
    error ZeroBid();

    struct EpochState {
        address leader;
        uint256 leadingBid;
        bool settled;
    }

    address public governance;
    IRebateVault public immutable rebateVault;

    /// @notice Block at which epoch 0 began for a pool
    mapping(PoolId => uint256) public startBlock;

    /// @notice Length of an auction epoch, in blocks
    mapping(PoolId => uint256) public epochBlocks;

    /// @notice Minimum bid accepted for a pool
    mapping(PoolId => uint256) public reservePrice;

    mapping(PoolId => mapping(uint256 => EpochState)) public epochs;

    /// @notice Cumulative amount a bidder has committed to an epoch
    mapping(PoolId => mapping(uint256 => mapping(address => uint256))) public bidOf;

    event PoolConfigured(PoolId indexed poolId, uint256 epochBlocks, uint256 reservePrice);
    event ReservePriceUpdated(PoolId indexed poolId, uint256 reservePrice);
    event GovernanceTransferred(address indexed oldGovernance, address indexed newGovernance);

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    constructor(address _governance, IRebateVault _rebateVault) {
        if (_governance == address(0) || address(_rebateVault) == address(0)) revert InvalidAddress();
        governance = _governance;
        rebateVault = _rebateVault;
    }

    /// @notice Opens auctions for a pool and anchors its epoch clock to the current block
    function configurePool(PoolId poolId, uint256 _epochBlocks, uint256 _reservePrice) external onlyGovernance {
        if (_epochBlocks == 0) revert InvalidEpochLength();

        if (startBlock[poolId] == 0) startBlock[poolId] = block.number;
        epochBlocks[poolId] = _epochBlocks;
        reservePrice[poolId] = _reservePrice;

        emit PoolConfigured(poolId, _epochBlocks, _reservePrice);
    }

    function setReservePrice(PoolId poolId, uint256 _reservePrice) external onlyGovernance {
        reservePrice[poolId] = _reservePrice;
        emit ReservePriceUpdated(poolId, _reservePrice);
    }

    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidAddress();
        emit GovernanceTransferred(governance, newGovernance);
        governance = newGovernance;
    }

    /// @inheritdoc IWeirAuction
    function currentEpoch(PoolId poolId) public view returns (uint256) {
        uint256 start = startBlock[poolId];
        if (start == 0) return 0;
        return (block.number - start) / epochBlocks[poolId];
    }

    /// @notice First block of an epoch, used by the hook to bound the priority window
    function epochStartBlock(PoolId poolId, uint256 epoch) public view returns (uint256) {
        return startBlock[poolId] + (epoch * epochBlocks[poolId]);
    }

    /// @inheritdoc IWeirAuction
    function winnerOf(PoolId poolId, uint256 epoch) external view returns (address) {
        return epochs[poolId][epoch].leader;
    }

    /// @inheritdoc IWeirAuction
    function bid(PoolId poolId) external payable {
        if (msg.value == 0) revert ZeroBid();
        if (startBlock[poolId] == 0) revert EpochNotStarted();

        // Bidding is always for the epoch after the one executing now, so an epoch's
        // leader is already fixed by the time its first swap can land.
        uint256 epoch = currentEpoch(poolId) + 1;

        uint256 total = bidOf[poolId][epoch][msg.sender] + msg.value;
        if (total < reservePrice[poolId]) revert BidBelowReserve();

        bidOf[poolId][epoch][msg.sender] = total;

        EpochState storage state = epochs[poolId][epoch];
        if (total > state.leadingBid) {
            state.leader = msg.sender;
            state.leadingBid = total;
        }

        emit BidPlaced(poolId, epoch, msg.sender, total);
    }

    /// @inheritdoc IWeirAuction
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

    /// @inheritdoc IWeirAuction
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
