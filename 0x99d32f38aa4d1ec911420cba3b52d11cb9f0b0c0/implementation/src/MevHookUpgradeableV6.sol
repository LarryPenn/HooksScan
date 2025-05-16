// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HookData} from "./MevHookUpgradeable.sol";
import {MevHookUpgradeableV5} from "./MevHookUpgradeableV5.sol";
import {BaseHookUpgradable} from "./BaseHookUpgradable.sol";

import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title MEV Hook – Upgradeable implementation V6
/// @dev Extends {MevHookUpgradeableV4} and maintains state layout compatibility for upgrades.
contract MevHookUpgradeableV6 is MevHookUpgradeableV5 {
    // -------------------------------------------------------------------
    // Custom Errors
    // -------------------------------------------------------------------

    /// @notice Thrown if the sent tip is below the required basefee amount
    /// @param amount The amount sent
    /// @param requiredMinimum The minimum amount required to cover the basefee
    /// @dev The minimum required amount is calculated as: basefee * 50839
    error TipTooLow(uint256 amount, uint256 requiredMinimum);

    /// @notice Thrown if trying to set the same signer address again
    /// @dev This is used to prevent unnecessary state changes and events
    error SameSigner();

    // -------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------

    /// @notice Emitted when the signer is updated
    event SignerUpdated(address indexed previous, address indexed current);

    // -------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------

    /// @notice The current authorized signer address
    address public signer;

    // -------------------------------------------------------------------
    // ETH Receive Logic
    // -------------------------------------------------------------------

    /// @notice Fallback function to receive ETH and redistribute it
    receive() external payable override nonReentrant {
        if (address(lastUsedPool.hooks) == address(0)) revert NoLastUsedPool();

        // Cache the state before modifying
        PoolKey memory pool = lastUsedPool;
        address _lastSwapper = lastSwapper;

        // Clear state for safety before external calls
        delete lastUsedPool;
        lastSwapper = address(0);
        unlockedBlock = 0;

        uint256 feeAmount = 0;
        uint256 amount = msg.value;

        // Calculate minimum required to cover basefee for the unlock tx
        uint256 minRequired = block.basefee * 50839;
        if (amount < minRequired) revert TipTooLow(amount, minRequired);

        // Subtract the required basefee from the amount to get the actual tip
        amount -= minRequired;

        // Transfer the required basefee to the signer
        (bool okBaseTransfer, ) = signer.call{value: minRequired}("");
        if (!okBaseTransfer) revert EthTransferFailed();

        // Calculate hook fee if any
        if (defaultHookFees.mevFeeBps > 0) {
            HookFees memory fee = getFeeConfig(pool.toId(), address(0));
            feeAmount = (amount * fee.mevFeeBps) / 10_000;
        }

        // Remaining amount goes to the pool
        uint256 poolAmount = amount - feeAmount;

        // Transfer fee to feeRecipient if set
        if (feeAmount > 0 && feeRecipient != address(0)) {
            (bool okFeeTransfer, ) = feeRecipient.call{value: feeAmount}("");
            if (!okFeeTransfer) revert EthTransferFailed();
        }

        // Donate remaining ETH to pool
        if (poolAmount > 0) {
            donateToPool(pool, poolAmount);
        }

        emit Tip(pool.toId(), _lastSwapper, poolAmount, feeAmount);
    }

    // -------------------------------------------------------------------
    // Admin: Signer Management
    // -------------------------------------------------------------------

    /// @notice Updates the signer, revoking the previous one and granting the new one
    /// @param newSigner The address of the new signer
    function setSigner(address newSigner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address previousSigner = signer;

        // Prevent redundant updates
        if (previousSigner == newSigner) revert SameSigner();

        // Revoke role from previous signer if any
        if (previousSigner != address(0)) {
            _revokeRole(SIGNER_ROLE, previousSigner);
        }

        // Update and grant SIGNER_ROLE to new signer
        signer = newSigner;
        _grantRole(SIGNER_ROLE, newSigner);

        emit SignerUpdated(previousSigner, newSigner);
    }
}
