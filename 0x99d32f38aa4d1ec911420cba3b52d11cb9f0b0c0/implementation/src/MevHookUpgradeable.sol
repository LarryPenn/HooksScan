// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;
import {console} from "forge-std/console.sol";

// Upgradeable OpenZeppelin imports
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// Uniswap v4 imports
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

// Local imports
import {BaseHookUpgradable} from "./BaseHookUpgradable.sol";

// *********************************************************************
// Structs used for authorization and swap operations
// *********************************************************************

/// @notice Struct containing authorization data for hook
struct HookData {
    // -------- FOR MEV AUCTIONS --------
    /// @notice nonce committed by MEV bot
    uint256 nonce;
    // --------- FOR SWAPS --------
    /// @notice Signature authorizing the swap
    bytes signature;
    /// @notice deadline after which the signature is invalid
    uint256 deadline;
    /// @notice the swapper address
    address swapper;
}

/// @notice Parameters for swap operations
struct SwapParams {
    /// @notice Unique identifier of the pool
    PoolId poolId;
    /// @notice Sender address
    address sender;
    /// @notice Whether to swap token0 for token1 (true) or vice versa (false)
    bool zeroForOne;
    /// @notice The desired input amount if negative (exactIn), or the desired output amount if positive (exactOut)
    int256 amountSpecified;
    /// @notice Timestamp after which the swap is invalid
    uint256 deadline;
}

// *********************************************************************
// MevHook Contract – Upgradeable via UUPS Proxy
// *********************************************************************

/// @notice Hook contract for MEV protection by requiring signed transactions
/// @dev Inherits from BaseHookUpgradable, EIP712Upgradeable, AccessControlUpgradeable, and ReentrancyGuardUpgradeable
contract MevHookUpgradeable is
    Initializable,
    UUPSUpgradeable,
    BaseHookUpgradable,
    EIP712Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeCast for int128;

    // ***************************************************************
    // Roles
    // ***************************************************************

    /// @notice New role for fee‐management functions (instead of DEFAULT_ADMIN_ROLE)
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    // SIGNER ROLE - can authorize nonces and swap signatures
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    // ***************************************************************
    // Errors
    // ***************************************************************

    /// @notice Thrown when a signature has already been used
    error SignatureAlreadyUsed();
    /// @notice Thrown when a swap signature is invalid or from an unauthorized signer
    error InvalidSwapSignature();
    /// @notice Thrown when a swap is attempted after its deadline has passed
    error SwapExpired();
    /// @notice Thrown when a signature's length is not exactly 65 bytes
    error InvalidSignatureLength();
    /// @notice Thrown when attempting to set a fee greater than 100% (10000 basis points)
    error FeeExceeds100Percent();
    /// @notice Thrown when attempting to set the fee recipient to the zero address
    error CannotSetZeroAddress();
    /// @notice Error thrown when an invalid nonce is provided
    error InvalidNonce();
    /// @notice Error thrown when a pool is not initialized with a wrapped native asset
    error PoolNotInitializedWithWrappedNativeAsset();
    /// @notice Error thrown when the last used pool is not set
    error NoLastUsedPool();
    /// @notice Error thrown when the ETH transfer fails
    error EthTransferFailed();

    // ***************************************************************
    // Events
    // ***************************************************************

    /// @notice Emitted when a tip is provided
    /// @param tipper The address providing the tip
    /// @param tipAmount The amount of the tip
    /// @param mevFeeAmount The amount taken as MEV fee
    event Tip(address indexed tipper, uint256 tipAmount, uint256 mevFeeAmount);
    /// @notice Emitted when a swap signature is used
    /// @param signatureHash The hash of the signature that was used
    event SwapSignatureUsed(bytes32 signatureHash);
    /// @notice Emitted when a nonce is used
    /// @param nonce The nonce value that was used
    event NonceUsed(uint256 indexed nonce);
    /// @notice Emitted when a fee config is set
    /// @param poolId The pool id that the fee config was set for
    /// @param mevFeeBps The new MEV fee in basis points
    /// @param swapFeeBps The new swap fee in basis points
    event FeeConfigSet(
        PoolId indexed poolId,
        address indexed swapper,
        uint256 mevFeeBps,
        uint256 swapFeeBps
    );
    // @notice Emitted when a fee recipient is set
    /// @param recipient The new fee recipient
    event FeeRecipientSet(address indexed recipient);

    // ***************************************************************
    // Storage Variables – Ordered for Upgrade Safety
    // ***************************************************************

    // Slot 0: Authorized nonce for MEV swaps
    uint256 public authorizedNonce;

    // Slot 1: Last used pool (from Uniswap v4)
    PoolKey public lastUsedPool;

    // Mapping to track used signatures (occupies its own slot per key)
    mapping(bytes32 => bool) public usedSignatures;

    // Swap fee recipient
    address payable public feeRecipient;

    // Array of all pools created
    PoolKey[] public allPools;

    // Total number of pools created
    uint256 public allPoolsLength;

    // ***************************************************************
    // Fee Configuration Structures and Mappings
    // ***************************************************************

    struct HookFees {
        uint256 mevFeeBps;
        uint256 swapFeeBps;
    }

    // Default hook fees
    HookFees public defaultHookFees;

    // Fee config per pool
    mapping(PoolId => HookFees) public hookFeesPerPool;

    // Fee config per swapper
    mapping(address => HookFees) public hookFeesPerSwapper;

    // ***************************************************************
    // Callback Data for ETH Donations
    // ***************************************************************
    struct DonateCallBackData {
        PoolKey key;
        uint256 amount;
        bool isCurrency0;
    }

    // ***************************************************************
    // Initializer (replaces constructor)
    // ***************************************************************
    /**
     * @notice Initialize the MevHook contract.
     * @param _poolManager Address of the pool manager contract.
     * @param owner Address to receive the DEFAULT_ADMIN_ROLE and FEE_MANAGER_ROLE.
     * @param signer Address that will have the SIGNER_ROLE.
     */
    function initialize(
        IPoolManager _poolManager,
        address owner,
        address signer
    ) external initializer {
        // Initialize inherited upgradeable contracts.
        __BaseHookUpgradable_init(_poolManager);
        __EIP712_init("MevHook", "1");
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // Set up roles.
        _grantRole(DEFAULT_ADMIN_ROLE, owner);
        _grantRole(SIGNER_ROLE, signer);
        _grantRole(FEE_MANAGER_ROLE, owner);
    }

    // ***************************************************************
    // UUPS Upgrade Authorization
    // ***************************************************************
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {}

    // ***************************************************************
    // Public & External Functions
    // ***************************************************************

    /// @notice Returns the EIP-712 hash of the swap parameters
    /// @param params The swap parameters to hash
    /// @return The EIP-712 hash
    function getSwapParamsHash(        SwapParams memory params    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(params));
        return _hashTypedDataV4(structHash);
    }

    /// @notice Allows a signer to authorize a nonce
    /// @param nonce The nonce to authorize
    function authorizeNonce(uint256 nonce) external onlyRole(SIGNER_ROLE) {
        authorizedNonce = nonce;
    }

    /// @notice Sets the last used pool.
    /// @param key The pool key to set
    function setLastUsedPool(
        PoolKey calldata key
    ) external onlyRole(SIGNER_ROLE) {
        lastUsedPool = key;
    }

    /// @notice Returns the hook permissions as expected by Uniswap v4.
    /// @return Hooks.Permissions struct with the hook's permissions
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        // Only the beforeSwap, beforeInitialize, afterInitialize, and afterSwap hooks are enabled.
        return
            Hooks.Permissions({
                beforeSwap: true,
                beforeInitialize: true,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // ***************************************************************
    // Internal Functions for Swap Signature Verification
    // ***************************************************************

    /// @notice Verifies the signature for swap operations
    /// @param poolId Unique identifier of the pool
    /// @param zeroForOne Direction of the swap
    /// @param amountSpecified Amount to swap
    /// @param deadline Timestamp after which the signature is invalid
    /// @param signature Signature authorizing the swap
    function _verifySwapSignature(
        PoolId poolId,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 deadline,
        address swapper,
        bytes memory signature
    ) internal returns (SwapParams memory) {
        SwapParams memory params = SwapParams({
            poolId: poolId,
            sender: swapper,
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            deadline: deadline
        });

        // Only allow EOA or zero address as swapper.
        if (swapper != tx.origin && swapper != address(0)) {
            revert InvalidSwapSignature();
        }

        bytes32 structHash = getSwapParamsHash(params);

        if (usedSignatures[structHash]) revert SignatureAlreadyUsed();

        // Recover the signer from the signature.
        address recoveredSigner = ECDSA.recover(structHash, signature);

        if (!hasRole(SIGNER_ROLE, recoveredSigner)) revert InvalidSwapSignature();

        if (block.timestamp > deadline) revert SwapExpired();

        usedSignatures[structHash] = true;

        return params;
    }

    // ***************************************************************
    // Uniswap v4 Hook Overrides
    // ***************************************************************

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
        if (tx.origin == address(0) || tx.gasprice == 0 || block.timestamp == 0) {
            return (
                BaseHookUpgradable.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }

        // Decode hook data.
        HookData memory data = abi.decode(hookData, (HookData));

        // If a nonce is used, verify it.
        if (data.nonce != 0) {
            if (data.nonce != authorizedNonce) {
                revert InvalidNonce();
            } else {
                emit NonceUsed(data.nonce);
                // Clear the nonce after use to prevent replay attacks.
                authorizedNonce = 0;
            }
        }

        // Signature based swaps
        if (data.nonce == 0) {
            if (data.signature.length != 65) revert InvalidSignatureLength();

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

        return (
            BaseHookUpgradable.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    /// @notice Hook called after swap execution.
    /// @param key Pool key containing token addresses and fee
    /// @param params Parameters for the swap
    /// @param delta Balance delta
    /// @return bytes4 Function selector
    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Get fee configuration.
        HookFees memory fee = getFeeConfig(key.toId(), tx.origin);

        if (fee.swapFeeBps > 0) {
            // if the amount specified is negative, and the swap is token0->token1, then the fee is on token0
            bool isToken0 = (params.amountSpecified < 0 == params.zeroForOne);
            Currency asset = key.currency1;
            int128 amount = delta.amount1();

            if (!isToken0) {
                asset = key.currency0;
                amount = delta.amount0();
            }

            if (amount < 0) amount = -amount;

            uint256 computedFee = (uint256(uint128(amount)) * fee.swapFeeBps) / 10_000;

            // Mint the fee to the fee recipient.
            poolManager.mint(address(feeRecipient), asset.toId(), computedFee);

            return (BaseHookUpgradable.afterSwap.selector, computedFee.toInt128());
        }

        return (BaseHookUpgradable.afterSwap.selector, 0);
    }

    /// @notice Ensures at least one asset is ETH during pool initialization.
    /// @param key The pool key containing information about the pool being initialized
    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal pure override returns (bytes4) {
        if (Currency.unwrap(key.currency0) != address(0))
            revert PoolNotInitializedWithWrappedNativeAsset();

        return BaseHookUpgradable.beforeInitialize.selector;
    }

    /// @notice Hook called after pool initialization.
    /// @param key The pool key containing information about the pool being initialized
    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24
    ) internal override returns (bytes4) {
        allPools.push(key);
        allPoolsLength++;

        return BaseHookUpgradable.afterInitialize.selector;
    }

    // ***************************************************************
    // Fee Configuration Functions
    // ***************************************************************

    // @notice Returns the fee configuration for a given pool id and swapper address
    /// @param poolId The pool id to get the fee config for
    /// @param swapper The swapper address to get the fee config for
    /// @return HookFees The fee configuration for the given pool id and swapper address
    function getFeeConfig(
        PoolId poolId,
        address swapper
    ) public view returns (HookFees memory) {
        HookFees memory fee = defaultHookFees;

        if (
            (hookFeesPerPool[poolId].mevFeeBps != 0 ||
                hookFeesPerPool[poolId].swapFeeBps != 0)
        ) {
            fee = hookFeesPerPool[poolId];
        }

        if (
            swapper != address(0) &&
            (hookFeesPerSwapper[swapper].mevFeeBps != 0 ||
                hookFeesPerSwapper[swapper].swapFeeBps != 0)
        ) {
            fee = hookFeesPerSwapper[swapper];
        }

        return fee;
    }

    /// @notice Sets the fee configuration for a given pool id
    /// @param poolId The pool id to set the fee config for
    /// @param fee The fee configuration to set
    /// @dev Emits a FeeConfigSet event
    /// @dev Can only be called by the FEE_MANAGER_ROLE
    function setFeeConfigForPool(
        PoolId poolId,
        HookFees memory fee
    ) external onlyRole(FEE_MANAGER_ROLE) {
        hookFeesPerPool[poolId] = fee;

        // If fee is 0, remove the pool from the list.
        if (fee.mevFeeBps == 0 && fee.swapFeeBps == 0) {
            delete hookFeesPerPool[poolId];
        }

        emit FeeConfigSet(poolId, address(0), fee.mevFeeBps, fee.swapFeeBps);
    }

    /// @notice Sets the fee configuration for a given swapper address
    /// @param swapper The swapper address to set the fee config for
    /// @param fee The fee configuration to set
    /// @dev Emits a FeeConfigSet event
    /// @dev Can only be called by the FEE_MANAGER_ROLE
    function setFeeConfigForSwapper(
        address swapper,
        HookFees memory fee
    ) external onlyRole(FEE_MANAGER_ROLE) {
        hookFeesPerSwapper[swapper] = fee;

        // If fee is 0, remove the swapper from the list.
        if (fee.mevFeeBps == 0 && fee.swapFeeBps == 0) {
            delete hookFeesPerSwapper[swapper];
        }

        emit FeeConfigSet(
            PoolId.wrap(0x0),
            swapper,
            fee.mevFeeBps,
            fee.swapFeeBps
        );
    }

    /// @notice Sets the default fee configuration
    /// @param fee The fee configuration to set
    /// @dev Emits a FeeConfigSet event
    /// @dev Can only be called by the FEE_MANAGER_ROLE
    function setDefaultFeeConfig(
        HookFees memory fee
    ) external onlyRole(FEE_MANAGER_ROLE) {
        defaultHookFees = fee;

        emit FeeConfigSet(
            PoolId.wrap(0x0),
            address(0),
            defaultHookFees.mevFeeBps,
            defaultHookFees.swapFeeBps
        );
    }

    // ***************************************************************
    // ETH Donation and Fallback Functionality
    // ***************************************************************

    /// @notice Fallback function to receive ETH and redistribute it
    /// @dev This function is called when ETH is sent to the contract
    receive() external virtual payable nonReentrant {
        if (address(lastUsedPool.hooks) == address(0)) revert NoLastUsedPool();
        // Update state before external calls to prevent reentrancy
        PoolKey memory pool = lastUsedPool;
        delete lastUsedPool;
        uint256 amount = msg.value;

        // Calculate distribution amounts based on percentages.
        uint256 feeAmount = 0;

        // If mevFee is set, use it for fee calculation.
        if (defaultHookFees.mevFeeBps > 0) {
            HookFees memory fee = getFeeConfig(pool.toId(), address(0));

            // mevFee is in basis points (1/100 of a percent).
            feeAmount = (amount * fee.mevFeeBps) / 10_000; // Fee based on mevFee
        }

        uint256 poolAmount = amount - feeAmount;

        // Send to fee recipient if set.
        if (feeAmount > 0 && feeRecipient != address(0)) {
            (bool success, ) = feeRecipient.call{value: feeAmount}("");
            if (!success) revert EthTransferFailed();
        }

        // Donate to the pool.
        if (poolAmount > 0) {
            donateToPool(pool, poolAmount);
        }

        emit Tip(msg.sender, poolAmount, feeAmount);
    }

    /// @notice Helper function to donate ETH to a pool
    /// @param key The pool key to donate to
    /// @param amount The amount to donate
    function donateToPool(PoolKey memory key, uint256 amount) internal {
        bool isCurrency0;
        if (key.currency0 == Currency.wrap(address(0))) {
            isCurrency0 = true;
        } else {
            isCurrency0 = false;
        }

        // Encode callback data.
        bytes memory callbackData = abi.encode(
            DonateCallBackData(key, amount, isCurrency0)
        );

        // Unlock the pool manager to donate.
        poolManager.unlock(callbackData);
    }

    function unlockCallback(
        bytes calldata data
    ) external onlyPoolManager returns (bytes memory) {
        DonateCallBackData memory decoded = abi.decode(data, (DonateCallBackData));

        uint256 amount0;
        uint256 amount1;

        if (decoded.isCurrency0) {
            amount0 = decoded.amount;
            amount1 = 0;
        } else {
            amount0 = 0;
            amount1 = decoded.amount;
        }

        poolManager.sync(Currency.wrap(address(0)));

        poolManager.donate(decoded.key, amount0, amount1, bytes(""));

        // Send the weth to the pool.
        poolManager.settle{value: decoded.amount}();
        poolManager.settle();

        return bytes("");
    }

    /// @notice Sets the fee recipient address
    /// @param recipient The new fee recipient address
    /// @dev Emits a FeeRecipientSet event
    /// @dev Can only be called by the FEE_MANAGER_ROLE
    function setFeeRecipient(
        address recipient
    ) external onlyRole(FEE_MANAGER_ROLE) {
        feeRecipient = payable(recipient);
        emit FeeRecipientSet(recipient);
    }
}
