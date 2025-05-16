// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IImmutableState} from "@uniswap/v4-periphery/src/interfaces/IImmutableState.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title Immutable State (Upgradable)
/// @notice A collection of state variables intended to be immutable, adapted for upgradeability
contract ImmutableStateUpgradable is Initializable, IImmutableState {
    /// @inheritdoc IImmutableState
    IPoolManager public override poolManager;

    /// @notice Thrown when the caller is not PoolManager
    error NotPoolManager();

    /// @notice Only allow calls from the PoolManager contract
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @notice Disable the default constructor in the implementation contract
    /// @dev This is required for upgradeable contracts to prevent initialization on deployment
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializer function to set the PoolManager address
    /// @param _poolManager The address of the PoolManager contract
    function __ImmutableState_init(IPoolManager _poolManager) internal onlyInitializing {
        poolManager = _poolManager;
    }
}