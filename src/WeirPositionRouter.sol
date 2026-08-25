// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

/// @title WeirPositionRouter
/// @notice Liquidity entrypoint that lets Weir credit rebates to the actual provider.
/// @dev v4 records the caller of `modifyLiquidity` as the position owner, so a hook can never
///      recover the human behind a shared router on its own. This router closes that gap two
///      ways: it names the caller as beneficiary in `hookData`, and it isolates each caller's
///      liquidity under a per-caller position salt so no one can withdraw someone else's.
///      WeirHook honours the declared beneficiary only for routers governance has allowlisted.
contract WeirPositionRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;

    error NotPoolManager();
    error NativeValueNotAccepted();
    error RefundFailed();

    IPoolManager public immutable poolManager;

    struct CallbackData {
        address owner;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
    }

    event LiquidityModified(
        address indexed owner, PoolKey key, int24 tickLower, int24 tickUpper, int256 liquidityDelta
    );

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Adds or removes liquidity on the caller's own position
    /// @param userSalt Lets one caller hold several positions over the same range
    /// @dev The v4 position salt is derived from the caller, so callers can only ever move their
    ///      own liquidity even though the router owns every position.
    function modifyLiquidity(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bytes32 userSalt
    ) external payable returns (BalanceDelta delta) {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidityDelta,
            salt: positionSalt(msg.sender, userSalt)
        });

        delta = abi.decode(
            poolManager.unlock(abi.encode(CallbackData({owner: msg.sender, key: key, params: params}))), (BalanceDelta)
        );

        _refundNative();

        emit LiquidityModified(msg.sender, key, tickLower, tickUpper, liquidityDelta);
    }

    /// @notice The v4 position salt this router uses on a caller's behalf
    function positionSalt(address owner, bytes32 userSalt) public pure returns (bytes32) {
        return keccak256(abi.encode(owner, userSalt));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        // Naming the beneficiary here is what lets the hook credit the rebate to a person
        // rather than to this contract.
        (BalanceDelta delta,) = poolManager.modifyLiquidity(data.key, data.params, abi.encode(data.owner));

        _resolve(data.key.currency0, data.owner, delta.amount0());
        _resolve(data.key.currency1, data.owner, delta.amount1());

        return abi.encode(delta);
    }

    /// @dev A negative delta is owed to the pool, a positive one is owed to the provider.
    function _resolve(Currency currency, address owner, int128 amount) private {
        if (amount < 0) {
            _settle(currency, owner, uint256(uint128(-amount)));
        } else if (amount > 0) {
            poolManager.take(currency, owner, uint256(uint128(amount)));
        }
    }

    function _settle(Currency currency, address payer, uint256 amount) private {
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(poolManager), amount);
            poolManager.settle();
        }
    }

    /// @dev Native pools take exact amounts, so any excess msg.value goes straight back.
    function _refundNative() private {
        uint256 balance = address(this).balance;
        if (balance == 0) return;

        (bool ok,) = msg.sender.call{value: balance}("");
        if (!ok) revert RefundFailed();
    }

    receive() external payable {
        // Only the pool manager returns native currency here; anything else is a mistake.
        if (msg.sender != address(poolManager)) revert NativeValueNotAccepted();
    }
}
