// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {WeirPositionRouter} from "../src/WeirPositionRouter.sol";
import {WeirSealedAuction} from "../src/WeirSealedAuction.sol";
import {WeirKeeper} from "../src/WeirKeeper.sol";
import {DemoERC20} from "../src/mocks/DemoERC20.sol";
import {TestnetOnly} from "./TestnetOnly.sol";

/// @notice Stands up a pool on a live network so the deployed stack has something to run against.
/// @dev Mints a fresh token pair, initialises the pool behind the Weir hook, opens the auction on
///      it, registers it with the keeper, and seeds liquidity through `WeirPositionRouter` — which
///      is what makes the deployer a rebate-earning provider rather than an anonymous router.
///
/// Usage:
///   forge script script/SetupDemoPool.s.sol:SetupDemoPool --rpc-url sepolia --broadcast
///
/// Required env:
///   PRIVATE_KEY, POOL_MANAGER, WEIR_HOOK, WEIR_AUCTION, WEIR_POSITION_ROUTER
/// Optional env:
///   WEIR_KEEPER (registers the pool for automated settlement)
///   EPOCH_BLOCKS (default 30), RESERVE_PRICE_WEI (default 0.0001 ether)
contract SetupDemoPool is Script, TestnetOnly {
    using PoolIdLibrary for PoolKey;

    /// @dev 1:1, the standard v4 starting price.
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;

    uint256 internal constant MINT_AMOUNT = 1_000_000e18;
    int256 internal constant LIQUIDITY = 1e18;

    function run() external testnetOnly returns (PoolKey memory key, PoolId poolId) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        WeirPositionRouter router = WeirPositionRouter(payable(vm.envAddress("WEIR_POSITION_ROUTER")));

        vm.startBroadcast(pk);

        (address token0, address token1) = _mintPair(vm.addr(pk), address(router));

        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(vm.envAddress("WEIR_HOOK"))
        });
        poolId = key.toId();

        IPoolManager(vm.envAddress("POOL_MANAGER")).initialize(key, SQRT_PRICE_1_1);
        _openAuction(poolId);

        // Going in through the router is what makes the deployer the rebate beneficiary; a direct
        // `modifyLiquidity` would credit whatever contract made the call.
        router.modifyLiquidity(key, TICK_LOWER, TICK_UPPER, LIQUIDITY, bytes32(0));

        vm.stopBroadcast();

        console2.log("token0        ", token0);
        console2.log("token1        ", token1);
        console2.log("liquidityFrom ", vm.addr(pk));
        console2.log("poolId        ");
        console2.logBytes32(PoolId.unwrap(poolId));
    }

    /// @dev v4 requires currency0 < currency1, and the pool id depends on that order.
    function _mintPair(address to, address router) internal returns (address token0, address token1) {
        address a = address(new DemoERC20("Weir Demo A", "WDA"));
        address b = address(new DemoERC20("Weir Demo B", "WDB"));
        (token0, token1) = a < b ? (a, b) : (b, a);

        DemoERC20(token0).mint(to, MINT_AMOUNT);
        DemoERC20(token1).mint(to, MINT_AMOUNT);
        DemoERC20(token0).approve(router, type(uint256).max);
        DemoERC20(token1).approve(router, type(uint256).max);
    }

    /// @dev The epoch clock is anchored here, so the auction only starts counting once the pool
    ///      actually exists.
    function _openAuction(PoolId poolId) internal {
        uint256 epochBlocks = vm.envOr("EPOCH_BLOCKS", uint256(30));
        uint256 reserveWei = vm.envOr("RESERVE_PRICE_WEI", uint256(0.0001 ether));

        WeirSealedAuction(vm.envAddress("WEIR_AUCTION")).configurePool(poolId, epochBlocks, reserveWei);

        address keeper = vm.envOr("WEIR_KEEPER", address(0));
        if (keeper != address(0)) WeirKeeper(keeper).registerPool(poolId);

        console2.log("epochBlocks   ", epochBlocks);
        console2.log("reserveWei    ", reserveWei);
    }
}
