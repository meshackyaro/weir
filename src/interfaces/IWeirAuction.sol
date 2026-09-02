// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @title IWeirAuction
/// @notice What `WeirHook` needs from an auction to police an epoch's priority window.
/// @dev Deliberately says nothing about how bids are placed or paid for. `WeirAuction` takes
///      plaintext bids as `msg.value`; `WeirSealedAuction` takes CoFHE ciphertexts against
///      pre-posted collateral. The hook works with either.
interface IWeirAuction {
    event EpochSettled(PoolId indexed poolId, uint256 indexed epoch, address winner, uint256 amount);

    /// @notice Epoch currently executing for a pool
    function currentEpoch(PoolId poolId) external view returns (uint256);

    /// @notice First block of an epoch, used by the hook to bound the priority window
    function epochStartBlock(PoolId poolId, uint256 epoch) external view returns (uint256);

    /// @notice Winner of an epoch. Address zero when nobody won, or when the result is not final
    ///         yet — either way the epoch is open to everyone, so a stalled auction cannot
    ///         freeze the pool.
    function winnerOf(PoolId poolId, uint256 epoch) external view returns (address);
}
