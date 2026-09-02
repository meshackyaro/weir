// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Refuses to run anywhere but a testnet.
/// @dev Weir is unaudited and says so. The scripts take a chain from an environment variable and
///      an RPC flag, which is exactly the shape of mistake that puts real funds behind code that
///      was never meant to hold any — so the allowed chains are named here rather than left to
///      whatever the shell happened to export.
abstract contract TestnetOnly {
    error NotATestnet(uint256 chainId);

    uint256 internal constant ETHEREUM_SEPOLIA = 11155111;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;
    uint256 internal constant ANVIL = 31337;

    modifier testnetOnly() {
        _requireTestnet();
        _;
    }

    function _requireTestnet() internal view {
        uint256 id = block.chainid;
        if (
            id != ETHEREUM_SEPOLIA && id != BASE_SEPOLIA && id != ARBITRUM_SEPOLIA && id != UNICHAIN_SEPOLIA
                && id != ANVIL
        ) revert NotATestnet(id);
    }
}
