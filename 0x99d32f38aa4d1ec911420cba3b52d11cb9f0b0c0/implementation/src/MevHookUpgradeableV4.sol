// SPDX-License-Identifier: MIT
//
pragma solidity ^0.8.24;

import {HookData} from "./MevHookUpgradeable.sol";
import {MevHookUpgradeableV3} from "./MevHookUpgradeableV3.sol";
import {BaseHookUpgradable} from "./BaseHookUpgradable.sol";

import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title MEV Hook – upgradeable implementation V4
/// @dev Extends {MevHookUpgradeableV3} and keeps state‑layout compatible upgrades.
contract MevHookUpgradeableV4 is MevHookUpgradeableV3 {
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
        lastSwapper  = tx.origin;

        return (
            BaseHookUpgradable.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    /// @notice Allows signature‑less swaps for the current block only
    function unlock(uint256 deadline) external onlyRole(SIGNER_ROLE) {
        if (block.timestamp > deadline) revert SwapExpired();

        unlockedBlock = block.number;
    }
}
