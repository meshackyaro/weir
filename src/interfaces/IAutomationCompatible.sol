// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The Chainlink Automation upkeep interface.
/// @dev `checkUpkeep` is simulated off chain by the Automation network, so it may read as much
///      state as it likes; `performUpkeep` is the transaction that actually lands and must
///      re-establish anything it depends on.
interface IAutomationCompatible {
    function checkUpkeep(bytes calldata checkData)
        external
        view
        returns (bool upkeepNeeded, bytes memory performData);

    function performUpkeep(bytes calldata performData) external;
}
