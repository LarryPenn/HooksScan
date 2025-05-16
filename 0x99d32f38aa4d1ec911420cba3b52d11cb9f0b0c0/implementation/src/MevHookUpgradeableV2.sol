// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {MevHookUpgradeable} from "./MevHookUpgradeable.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @dev New implementation of the MEV hook contract.
/// @dev This contract is an upgrade of the previous one, which had a bug in the event signature.
/// @dev The bug was that the event emitted didn't had the poolId included in the event.
contract MevHookUpgradeableV2 is MevHookUpgradeable {
    /// @notice Emitted when a tip is provided
    /// @param poolId The ID of the pool
    /// @param tipper The address providing the tip
    /// @param tipAmount The amount of the tip
    /// @param mevFeeAmount The amount taken as MEV fee
    event Tip(
        PoolId poolId,
        address indexed tipper,
        uint256 tipAmount,
        uint256 mevFeeAmount
    );

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

        emit Tip(pool.toId(), msg.sender, poolAmount, feeAmount);
    }
}
