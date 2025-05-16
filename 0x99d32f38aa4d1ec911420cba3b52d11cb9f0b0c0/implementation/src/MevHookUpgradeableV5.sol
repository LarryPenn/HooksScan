// SPDX-License-Identifier: MIT
//
pragma solidity ^0.8.24;

import {HookData} from "./MevHookUpgradeable.sol";
import {MevHookUpgradeableV4} from "./MevHookUpgradeableV4.sol";
import {BaseHookUpgradable} from "./BaseHookUpgradable.sol";

import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title MEV Hook – upgradeable implementation V5
/// @dev Extends {MevHookUpgradeableV4} and keeps state‑layout compatible upgrades.
contract MevHookUpgradeableV5 is MevHookUpgradeableV4 {
    /// @notice Hook called before swap execution.
    /// @param key Pool key containing token addresses and fee
    /// @param params Parameters for the swap
    /// @param hookData Data containing authorization signature
    /// @return bytes4 Function selector
    function _beforeSwap(
        address, // removed 'sender' parameter name since it's unused
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Allow bypass in simulation (tx.origin is zero, zero gas price, or zero block timestamp).
        if (
            tx.origin == address(0) || tx.gasprice == 0 || block.timestamp == 0
        ) {
            return (
                BaseHookUpgradable.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }

        if (unlockedBlock == block.number) {
            lastUsedPool = key;
            lastSwapper = tx.origin;

            // pool is unlocked, no need for signature verification
            return (
                BaseHookUpgradable.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }

        // Signature swaps are allowed only when there is a hookData
        if (hookData.length == 0) revert Locked();

        HookData memory data = abi.decode(hookData, (HookData));

        if (data.signature.length != 65) revert InvalidSignatureLength();

        // Signature verification
        _verifySwapSignature(
            key.toId(),
            params.zeroForOne,
            params.amountSpecified,
            data.deadline,
            data.swapper,
            data.signature
        );

        emit SwapSignatureUsed(keccak256(data.signature));

        lastUsedPool = key;
        lastSwapper = tx.origin;

        return (
            BaseHookUpgradable.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    /// @notice Fallback function to receive ETH and redistribute it
    receive() external payable virtual override nonReentrant {
        if (address(lastUsedPool.hooks) == address(0)) revert NoLastUsedPool();

        // copy the data we still need
        PoolKey memory pool = lastUsedPool;
        address _lastSwapper = lastSwapper;

        // wipe state before any external interaction
        delete lastUsedPool;
        lastSwapper  = address(0);
        unlockedBlock = 0;

        uint256 amount = msg.value;
        uint256 feeAmount = 0;

        if (defaultHookFees.mevFeeBps > 0) {
            HookFees memory fee = getFeeConfig(pool.toId(), address(0));
            feeAmount = (amount * fee.mevFeeBps) / 10_000;
        }

        uint256 poolAmount = amount - feeAmount;

        if (feeAmount > 0 && feeRecipient != address(0)) {
            (bool success, ) = feeRecipient.call{value: feeAmount}("");
            if (!success) revert EthTransferFailed();
        }

        if (poolAmount > 0) {
            donateToPool(pool, poolAmount);
        }

        emit Tip(pool.toId(), _lastSwapper, poolAmount, feeAmount);
    }
}
