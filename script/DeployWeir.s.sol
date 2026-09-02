// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery-test/shared/HookMiner.sol";

import {WeirHook} from "../src/WeirHook.sol";
import {WeirAuction} from "../src/WeirAuction.sol";
import {WeirSealedAuction} from "../src/WeirSealedAuction.sol";
import {RebateVault} from "../src/RebateVault.sol";
import {WeirPositionRouter} from "../src/WeirPositionRouter.sol";
import {FairPriceOracle} from "../src/FairPriceOracle.sol";
import {IWeirAuction} from "../src/interfaces/IWeirAuction.sol";
import {IRebateVault} from "../src/interfaces/IRebateVault.sol";

/// @notice Deploys the Weir stack and wires its authorizations.
/// @dev The hook is mined to an address whose bottom 14 bits encode its permissions, then
///      deployed through the canonical CREATE2 proxy so the mined salt holds on any chain.
///
/// Usage:
///   forge script script/DeployWeir.s.sol:DeployWeir \
///     --rpc-url unichain_sepolia --broadcast --verify
///
/// Required env:
///   PRIVATE_KEY, POOL_MANAGER
/// Optional env:
///   GOVERNANCE (defaults to the broadcasting address)
///   PRIORITY_WINDOW_BLOCKS (defaults to 2)
///   SEALED_BIDS (defaults to false; requires a chain where CoFHE is deployed)
contract DeployWeir is Script {
    /// @dev Deterministic CREATE2 proxy, present at the same address on every major chain.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 internal constant DEFAULT_PRIORITY_WINDOW = 2;

    function run()
        external
        returns (
            RebateVault vault,
            IWeirAuction auction,
            WeirHook hook,
            WeirPositionRouter router,
            FairPriceOracle oracle
        )
    {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address governance = vm.envOr("GOVERNANCE", vm.addr(pk));
        bool sealedBids = vm.envOr("SEALED_BIDS", false);

        vm.startBroadcast(pk);

        vault = new RebateVault(governance);
        // Sealed bidding needs CoFHE on the target chain. Where it is not deployed the plaintext
        // auction drives the same hook, so a pool can adopt Weir now and seal its bids later.
        auction = sealedBids
            ? IWeirAuction(address(new WeirSealedAuction(governance, IRebateVault(address(vault)))))
            : IWeirAuction(address(new WeirAuction(governance, IRebateVault(address(vault)))));
        oracle = new FairPriceOracle(governance);

        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        hook = _deployHook(poolManager, auction, vault, governance);
        router = new WeirPositionRouter(poolManager);

        // The auction funds the vault and the hook reports liquidity to it, so both need vault
        // authorization; the router needs the hook's trust to name providers. Only governance
        // can grant either.
        bool deployerIsGovernance = governance == vm.addr(pk);
        if (deployerIsGovernance) {
            vault.setAuthorized(address(auction), true);
            vault.setAuthorized(address(hook), true);
            hook.setTrustedRouter(address(router), true);
        }

        vm.stopBroadcast();

        if (!deployerIsGovernance) {
            console2.log("ACTION REQUIRED, from governance:");
            console2.log("  vault.setAuthorized(auction, true)");
            console2.log("  vault.setAuthorized(hook, true)");
            console2.log("  hook.setTrustedRouter(router, true)");
        }

        console2.log("RebateVault    ", address(vault));
        console2.log(sealedBids ? "SealedAuction  " : "WeirAuction    ", address(auction));
        console2.log("WeirHook       ", address(hook));
        console2.log("PositionRouter ", address(router));
        console2.log("FairPriceOracle", address(oracle));
        console2.log("governance     ", governance);
    }

    /// @dev Mines a salt so the hook lands on an address whose bottom 14 bits are exactly the
    ///      permissions it implements, then deploys it through the CREATE2 proxy so the same
    ///      salt yields the same address on every chain.
    function _deployHook(IPoolManager poolManager, IWeirAuction auction, RebateVault vault, address governance)
        internal
        returns (WeirHook hook)
    {
        uint256 priorityWindow = vm.envOr("PRIORITY_WINDOW_BLOCKS", DEFAULT_PRIORITY_WINDOW);

        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        bytes memory args = abi.encode(poolManager, auction, IRebateVault(address(vault)), governance, priorityWindow);

        (address expected, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, type(WeirHook).creationCode, args);

        hook = new WeirHook{salt: salt}(poolManager, auction, IRebateVault(address(vault)), governance, priorityWindow);
        require(address(hook) == expected, "DeployWeir: hook address mismatch");
    }
}
