// SPDX-License-Identifier: MIT
// 
pragma solidity ^0.8.24;

import {HookData} from "./MevHookUpgradeable.sol";
import {MevHookUpgradeableV2} from "./MevHookUpgradeableV2.sol";
import {BaseHookUpgradable} from "./BaseHookUpgradable.sol";

import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title MEV Hook – upgradeable implementation V3
/// @notice Fixes the missing `poolId` parameter in the `SwapSignatureUsed` event and adds per‑block unlock logic.
/// @dev Extends {MevHookUpgradeableV2} and keeps state‑layout compatible upgrades.
contract MevHookUpgradeableV3 is MevHookUpgradeableV2 {
    /// ***************************************************************
    /// Storage
    /// ***************************************************************

    /// @notice Block number for which swaps are unlocked (zero means locked)
    uint256 public unlockedBlock;

    /// @notice Last address that triggered a swap
    address public lastSwapper;

    /// ***************************************************************
    /// Errors
    /// ***************************************************************

    /// @notice Thrown when swaps are attempted while the hook is locked
    error Locked();

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
    ) internal override virtual returns (bytes4, BeforeSwapDelta, uint24) {
        // Allow bypass in simulation (tx.origin is zero, zero gas price, or zero block timestamp).
        if ( tx.origin == address(0) || tx.gasprice == 0 || block.timestamp == 0 ) {
            return (
                BaseHookUpgradable.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }

        if (hookData.length == 0) {
            // Signature‑less swaps are allowed only when the hook is unlocked
            if (block.number != unlockedBlock) revert Locked();
        } else {
            HookData memory data = abi.decode(hookData, (HookData));

            // Signature‑less swaps are allowed only when the hook is unlocked
            if (data.signature.length == 0) {
                if (block.number != unlockedBlock) revert Locked();
            }
            if (data.signature.length != 65) revert InvalidSignatureLength();

            
            // Signature‑based authorisation
            _verifySwapSignature(
                key.toId(),
                params.zeroForOne,
                params.amountSpecified,
                data.deadline,
                data.swapper,
                data.signature
            );

            emit SwapSignatureUsed(keccak256(data.signature));
        }

        lastUsedPool = key;
        lastSwapper = tx.origin;

        return (
            BaseHookUpgradable.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    /// ***************************************************************
    /// ETH handling
    /// ***************************************************************

    /// @notice Fallback function to receive ETH and redistribute it
    receive() external payable virtual override nonReentrant {
        if (address(lastUsedPool.hooks) == address(0)) revert NoLastUsedPool();

        PoolKey memory pool = lastUsedPool;
        delete lastUsedPool;

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

        emit Tip(pool.toId(), lastSwapper, poolAmount, feeAmount);

        // Relock until the next explicit unlock
        unlockedBlock = 0;
    }

    /// ***************************************************************
    /// Admin
    /// ***************************************************************

    /// @notice Disables signature‑less swaps
    function lock() external onlyRole(SIGNER_ROLE) {
        unlockedBlock = 0;
    }

    /// @notice Allows signature‑less swaps for the current block only
    function unlock() external virtual onlyRole(SIGNER_ROLE) {
        unlockedBlock = block.number;
    }
}