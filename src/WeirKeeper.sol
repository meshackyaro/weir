// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {WeirSealedAuction} from "./WeirSealedAuction.sol";
import {IAutomationCompatible} from "./interfaces/IAutomationCompatible.sol";

/// @title WeirKeeper
/// @notice Drives the sealed auction's epoch lifecycle from Chainlink Automation.
///
/// @dev The sealed auction needs two transactions per epoch that nobody has a private reason to
///      send. Bidders want their collateral back, so they will settle an epoch eventually, but
///      "eventually" is too late: a winner has to be decrypted and on record *before* their epoch
///      begins, or the priority slot they paid for goes unused. This contract is what makes the
///      schedule somebody's job.
///
///      Both actions it drives are permissionless on the auction and carry their own guards, so
///      this keeper holds no privilege the public does not. If Automation stops, LPs are still
///      paid — anyone can call the auction directly. What is lost is punctuality, not funds.
contract WeirKeeper is IAutomationCompatible {
    error Unauthorized();
    error InvalidAddress();
    error PoolAlreadyRegistered();
    error PoolNotRegistered();
    error NothingToDo();

    enum Action {
        None,
        Close,
        Settle
    }

    /// @notice How many epochs back the keeper will look to pick up work it missed.
    /// @dev Bounded on purpose. An outage longer than this leaves old epochs unsettled, and the
    ///      permissionless path on the auction is the backstop — the bidders whose collateral is
    ///      locked have every reason to use it.
    uint256 public constant LOOKBACK_EPOCHS = 3;

    WeirSealedAuction public immutable auction;

    address public governance;

    /// @notice Chainlink's forwarder for this upkeep, once it is known.
    /// @dev Optional. Leaving it unset keeps `performUpkeep` open to anyone, which is harmless
    ///      here because every action behind it is already permissionless.
    address public forwarder;

    PoolId[] internal _pools;

    /// @dev One-based, so zero reads as "not registered".
    mapping(PoolId => uint256) internal _poolIndex;

    event PoolRegistered(PoolId indexed poolId);
    event PoolDeregistered(PoolId indexed poolId);
    event ForwarderUpdated(address indexed forwarder);
    event GovernanceTransferred(address indexed oldGovernance, address indexed newGovernance);
    event UpkeepPerformed(PoolId indexed poolId, uint256 indexed epoch, Action action);

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    constructor(WeirSealedAuction _auction, address _governance) {
        if (address(_auction) == address(0) || _governance == address(0)) revert InvalidAddress();
        auction = _auction;
        governance = _governance;
    }

    // ============ Governance ============

    function registerPool(PoolId poolId) external onlyGovernance {
        if (_poolIndex[poolId] != 0) revert PoolAlreadyRegistered();

        _pools.push(poolId);
        _poolIndex[poolId] = _pools.length;

        emit PoolRegistered(poolId);
    }

    function deregisterPool(PoolId poolId) external onlyGovernance {
        uint256 index = _poolIndex[poolId];
        if (index == 0) revert PoolNotRegistered();

        PoolId moved = _pools[_pools.length - 1];
        _pools[index - 1] = moved;
        _poolIndex[moved] = index;
        _pools.pop();
        delete _poolIndex[poolId];

        emit PoolDeregistered(poolId);
    }

    function setForwarder(address _forwarder) external onlyGovernance {
        forwarder = _forwarder;
        emit ForwarderUpdated(_forwarder);
    }

    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidAddress();
        emit GovernanceTransferred(governance, newGovernance);
        governance = newGovernance;
    }

    // ============ Views ============

    function pools() external view returns (PoolId[] memory) {
        return _pools;
    }

    function isRegistered(PoolId poolId) public view returns (bool) {
        return _poolIndex[poolId] != 0;
    }

    /// @notice The single piece of work the keeper would do for a pool right now
    /// @dev Settling outranks closing. A closed epoch is one whose winner is already owed a slot,
    ///      and that deadline is the one that expires; bidding closes a whole epoch early and can
    ///      afford to wait a block.
    function pendingWork(PoolId poolId) public view returns (Action action, uint256 epoch) {
        uint256 current = auction.currentEpoch(poolId);
        uint256 from = current > LOOKBACK_EPOCHS ? current - LOOKBACK_EPOCHS : 0;

        // Bidding for `current + 1` closed when this epoch began, so that is the newest epoch
        // with anything to do.
        uint256 to = current + 1;

        for (uint256 e = from; e <= to; ++e) {
            if (auction.settlementReady(poolId, e)) return (Action.Settle, e);
        }

        for (uint256 e = from; e <= to; ++e) {
            if (auction.biddingClosable(poolId, e) && auction.hasBids(poolId, e)) return (Action.Close, e);
        }

        return (Action.None, 0);
    }

    // ============ Automation ============

    /// @inheritdoc IAutomationCompatible
    /// @dev Returns the first pool with work rather than batching. Automation re-runs this every
    ///      block, so a backlog drains one transaction at a time without any of them being large
    ///      enough to hit a gas ceiling and strand the whole queue.
    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData) {
        uint256 length = _pools.length;

        for (uint256 i = 0; i < length; ++i) {
            PoolId poolId = _pools[i];
            (Action action, uint256 epoch) = pendingWork(poolId);
            if (action != Action.None) return (true, abi.encode(action, poolId, epoch));
        }

        return (false, "");
    }

    /// @inheritdoc IAutomationCompatible
    /// @dev `performData` arrives from an off-chain simulation and is not trusted. It does not
    ///      need to be: both calls below are permissionless and revert on their own if the work
    ///      is not actually due. The registration check is only here so a stray caller cannot
    ///      spend this upkeep's gas allowance on a pool nobody asked it to watch.
    function performUpkeep(bytes calldata performData) external {
        address expected = forwarder;
        if (expected != address(0) && msg.sender != expected) revert Unauthorized();

        (Action action, PoolId poolId, uint256 epoch) = abi.decode(performData, (Action, PoolId, uint256));
        if (!isRegistered(poolId)) revert PoolNotRegistered();

        if (action == Action.Settle) {
            auction.settleEpoch(poolId, epoch);
        } else if (action == Action.Close) {
            auction.closeBidding(poolId, epoch);
        } else {
            revert NothingToDo();
        }

        emit UpkeepPerformed(poolId, epoch, action);
    }
}
