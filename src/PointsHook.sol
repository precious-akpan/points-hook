// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {ERC1155} from "solmate/src/tokens/ERC1155.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

/// @title PointsHook
/// @notice A Uniswap V4 hook that awards ERC1155 points to users during swaps and enables redemption for ETH rewards
/// @dev This contract extends BaseHook to integrate with Uniswap V4 and implements ERC1155 for points token management.
///      
///      ARCHITECTURE:
///      - Points Minting: Users earn points (20% of ETH spent) during swaps via the afterSwap hook
///      - Redemption System: Users can redeem accumulated points for ETH rewards
///      - Per-Pool Configuration: Each pool has independent redemption parameters (rate, threshold, owner)
///      - Reward Pool Management: Pool owners can fund and withdraw from reward pools
///      
///      SECURITY CONSIDERATIONS:
///      - Follows checks-effects-interactions (CEI) pattern to prevent reentrancy
///      - Uses SafeTransferLib for safe ETH transfers with proper error handling
///      - Validates rate bounds to prevent integer overflow in redemption calculations
///      - Solidity 0.8.26 provides built-in overflow/underflow protection
///      
///      INTEGRATION:
///      - Uniswap V4: Hooks into beforeInitialize and afterSwap
///      - ERC1155: Leverages for points token management (burn, mint, balanceOf)
///      - Backward Compatible: Existing PointsHook functionality unchanged
contract PointsHook is BaseHook, ERC1155 {
    /// @notice Configuration for a pool's redemption system
    /// @param owner The address with administrative privileges for this pool
    /// @param redemptionRate The wei per point conversion rate (e.g., 1000 = 1 point = 1000 wei)
    /// @param minRedemption The minimum points required for a redemption transaction
    struct PoolConfig {
        address owner;
        uint256 redemptionRate;
        uint256 minRedemption;
    }

    // ============ State Variables ============

    /// @notice Pool configuration mapping: poolId => PoolConfig
    /// @dev Stores owner, redemption rate, and minimum threshold for each pool
    mapping(PoolId => PoolConfig) public poolConfigs;

    /// @notice Reward pool balances: poolId => ETH balance in wei
    /// @dev Tracks available ETH for redemption payouts, isolated per pool
    mapping(PoolId => uint256) public rewardPools;

    // ============ Custom Errors ============

    /// @notice Thrown when user has insufficient points for redemption
    /// @param available The user's current points balance
    /// @param required The points amount requested for redemption
    error InsufficientPoints(uint256 available, uint256 required);

    /// @notice Thrown when reward pool has insufficient ETH
    /// @param available The current reward pool balance
    /// @param required The ETH amount needed for redemption
    error InsufficientRewardPool(uint256 available, uint256 required);

    /// @notice Thrown when redemption amount is below minimum threshold
    /// @param amount The redemption amount attempted
    /// @param minimum The minimum required
    error BelowMinimumRedemption(uint256 amount, uint256 minimum);

    /// @notice Thrown when caller is not the pool owner
    /// @param caller The address that attempted the operation
    /// @param owner The actual pool owner
    error NotPoolOwner(address caller, address owner);

    /// @notice Thrown when attempting to set redemption rate to zero or above safe bounds
    /// @dev Rate must be > 0 and <= type(uint256).max / 2^128 to prevent overflow
    error InvalidRedemptionRate();

    /// @notice Thrown when attempting to redeem zero points
    error ZeroRedemption();

    /// @notice Thrown when attempting to fund with zero ETH
    error ZeroFunding();

    /// @notice Thrown when redemption rate is not set for a pool
    /// @dev Rate must be set before users can redeem points
    error RedemptionRateNotSet();

    /// @notice Thrown when attempting to transfer ownership to zero address
    error InvalidOwnerAddress();

    /// @notice Thrown when ETH transfer fails
    /// @dev Indicates SafeTransferLib.safeTransferETH failed
    error ETHTransferFailed();

    // ============ Events ============

    /// @notice Emitted when points are redeemed for ETH
    /// @param user The user who redeemed points
    /// @param poolId The pool identifier
    /// @param pointsRedeemed The number of points burned
    /// @param ethAmount The amount of ETH transferred
    event PointsRedeemed(
        address indexed user,
        PoolId indexed poolId,
        uint256 pointsRedeemed,
        uint256 ethAmount
    );

    /// @notice Emitted when redemption rate is updated
    /// @param poolId The pool identifier
    /// @param oldRate The previous rate (wei per point)
    /// @param newRate The new rate (wei per point)
    event RedemptionRateUpdated(
        PoolId indexed poolId,
        uint256 oldRate,
        uint256 newRate
    );

    /// @notice Emitted when minimum redemption threshold is updated
    /// @param poolId The pool identifier
    /// @param oldThreshold The previous threshold (minimum points)
    /// @param newThreshold The new threshold (minimum points)
    event MinimumRedemptionUpdated(
        PoolId indexed poolId,
        uint256 oldThreshold,
        uint256 newThreshold
    );

    /// @notice Emitted when reward pool is funded
    /// @param poolId The pool identifier
    /// @param funder The address that funded the pool
    /// @param amount The amount of ETH deposited (wei)
    event RewardPoolFunded(
        PoolId indexed poolId,
        address indexed funder,
        uint256 amount
    );

    /// @notice Emitted when rewards are withdrawn
    /// @param poolId The pool identifier
    /// @param owner The pool owner who withdrew
    /// @param amount The amount of ETH withdrawn (wei)
    event RewardsWithdrawn(
        PoolId indexed poolId,
        address indexed owner,
        uint256 amount
    );

    /// @notice Emitted when pool ownership is transferred
    /// @param poolId The pool identifier
    /// @param previousOwner The previous owner
    /// @param newOwner The new owner
    event PoolOwnershipTransferred(
        PoolId indexed poolId,
        address indexed previousOwner,
        address indexed newOwner
    );

    // ============ Existing Errors ============

    error Currency0IsNotAddressZero();
    constructor(IPoolManager _manager) BaseHook(_manager) {}

    // Set up hook permissions to return `true`
    // for the two hook functions we are using
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // Implement the ERC1155 `uri` function
    function uri(uint256) public view virtual override returns (string memory) {
        return "https://api.example.com/token/{id}";
    }

    /// @notice Hook called before pool initialization
    /// @param sender The address initializing the pool (will become pool owner)
    /// @param poolKey The pool key being initialized
    /// @return The selector of this function
    /// @dev Captures the pool owner and initializes default configuration values
    /// @dev Validates that currency0 is ETH (address zero) for this hook
    /// @dev Emits no events; pool configuration is initialized with zero rate and threshold
    function _beforeInitialize(
        address sender,
        PoolKey calldata poolKey,
        uint160 // sqrtPriceX96 - unused but required by hook interface
    ) internal override returns (bytes4) {
    // Validate that currency0 is ETH (address zero)
    if (!poolKey.currency0.isAddressZero()) {
        revert Currency0IsNotAddressZero();
    }

    // Capture the pool owner and initialize default configuration
    PoolId poolId = poolKey.toId();
    poolConfigs[poolId] = PoolConfig({
        owner: sender,
        redemptionRate: 0,
        minRedemption: 0
    });

    return this.beforeInitialize.selector;
}

    /// @notice Transfer pool ownership to a new address
    /// @param poolId The pool identifier
    /// @param newOwner The new owner address (cannot be zero address)
    /// @dev Only callable by current pool owner
    /// @dev Reverts with InvalidOwnerAddress if newOwner is address(0)
    /// @dev Reverts with NotPoolOwner if caller is not the current pool owner
    /// @dev Emits PoolOwnershipTransferred event with previous and new owner
    function transferPoolOwnership(PoolId poolId, address newOwner) external {
        // Validate newOwner is not address(0)
        if (newOwner == address(0)) {
            revert InvalidOwnerAddress();
        }

        // Check caller is current pool owner
        address currentOwner = poolConfigs[poolId].owner;
        if (msg.sender != currentOwner) {
            revert NotPoolOwner(msg.sender, currentOwner);
        }

        // Update pool owner
        poolConfigs[poolId].owner = newOwner;

        // Emit event
        emit PoolOwnershipTransferred(poolId, currentOwner, newOwner);
    }

    // ============ View Functions ============

    /// @notice Get the pool owner
    /// @param poolId The pool identifier
    /// @return The owner address (address(0) if pool not initialized)
    function getPoolOwner(PoolId poolId) external view returns (address) {
        return poolConfigs[poolId].owner;
    }

    /// @notice Get the redemption rate for a pool
    /// @param poolId The pool identifier
    /// @return The rate in wei per point (0 if not set)
    function getRedemptionRate(PoolId poolId) external view returns (uint256) {
        return poolConfigs[poolId].redemptionRate;
    }

    /// @notice Get the minimum redemption threshold for a pool
    /// @param poolId The pool identifier
    /// @return The minimum points required (0 if disabled)
    function getMinimumRedemption(PoolId poolId) external view returns (uint256) {
        return poolConfigs[poolId].minRedemption;
    }

    /// @notice Get the reward pool balance for a pool
    /// @param poolId The pool identifier
    /// @return The ETH balance in wei
    function getRewardPoolBalance(PoolId poolId) external view returns (uint256) {
        return rewardPools[poolId];
    }

    /// @notice Get user's points balance for a pool
    /// @param user The user address
    /// @param poolId The pool identifier
    /// @return The points balance (ERC1155 token balance)
    function getPointsBalance(address user, PoolId poolId) external view returns (uint256) {
        return this.balanceOf(user, uint256(PoolId.unwrap(poolId)));
    }

    /// @notice Calculate ETH amount for a given points amount
    /// @param poolId The pool identifier
    /// @param pointsAmount The number of points
    /// @return The ETH amount in wei (pointsAmount * redemptionRate)
    function calculateRedemptionValue(PoolId poolId, uint256 pointsAmount) external view returns (uint256) {
        return pointsAmount * poolConfigs[poolId].redemptionRate;
    }

    // ============ Configuration Functions ============

    /// @notice Set the redemption rate for a pool
    /// @param poolId The pool identifier
    /// @param rate Wei per point (must be > 0 and within safe bounds)
    /// @dev Only callable by pool owner
    /// @dev Emits RedemptionRateUpdated event
    /// @dev SECURITY: Validates rate bounds to prevent overflow in redemption calculations.
    ///      Assumes maximum points balance of 2^128 to calculate safe rate bounds.
    ///      Maximum safe rate = type(uint256).max / 2^128 to ensure pointsAmount * rate doesn't overflow.
    function setRedemptionRate(PoolId poolId, uint256 rate) external {
        // Validate rate is not zero
        if (rate == 0) {
            revert InvalidRedemptionRate();
        }

        // Validate rate is within safe bounds to prevent overflow
        // Maximum safe rate = type(uint256).max / 2^128
        // This ensures that even with maximum expected points balance (2^128),
        // the multiplication pointsAmount * rate will not overflow uint256
        uint256 maxSafeRate = type(uint256).max / (2 ** 128);
        if (rate > maxSafeRate) {
            revert InvalidRedemptionRate();
        }

        // Check caller is pool owner
        address owner = poolConfigs[poolId].owner;
        if (msg.sender != owner) {
            revert NotPoolOwner(msg.sender, owner);
        }

        // Store old rate for event
        uint256 oldRate = poolConfigs[poolId].redemptionRate;

        // Update rate
        poolConfigs[poolId].redemptionRate = rate;

        // Emit event
        emit RedemptionRateUpdated(poolId, oldRate, rate);
    }

    /// @notice Set the minimum redemption threshold for a pool
    /// @param poolId The pool identifier
    /// @param minPoints Minimum points required (0 to disable threshold checking)
    /// @dev Only callable by pool owner
    /// @dev Reverts with NotPoolOwner if caller is not the pool owner
    /// @dev Emits MinimumRedemptionUpdated event with old and new threshold
    function setMinimumRedemption(PoolId poolId, uint256 minPoints) external {
        // Check caller is pool owner
        address owner = poolConfigs[poolId].owner;
        if (msg.sender != owner) {
            revert NotPoolOwner(msg.sender, owner);
        }

        // Store old threshold for event
        uint256 oldThreshold = poolConfigs[poolId].minRedemption;

        // Update threshold
        poolConfigs[poolId].minRedemption = minPoints;

        // Emit event
        emit MinimumRedemptionUpdated(poolId, oldThreshold, minPoints);
    }

    /// @notice Fund a pool's reward pool with ETH
    /// @param poolId The pool identifier
    /// @dev Callable by anyone (permissionless)
    /// @dev Must send ETH with transaction (msg.value > 0)
    /// @dev Reverts with ZeroFunding if msg.value is zero
    /// @dev Emits RewardPoolFunded event with poolId, sender, and amount
    function fundRewardPool(PoolId poolId) external payable {
        // Validate msg.value > 0
        if (msg.value == 0) {
            revert ZeroFunding();
        }

        // Add msg.value to rewardPools[poolId]
        rewardPools[poolId] += msg.value;

        // Emit RewardPoolFunded event
        emit RewardPoolFunded(poolId, msg.sender, msg.value);
    }

    /// @notice Withdraw excess ETH from reward pool
    /// @param poolId The pool identifier
    /// @param amount Amount of ETH to withdraw in wei
    /// @dev Only callable by pool owner
    /// @dev Reverts with NotPoolOwner if caller is not the pool owner
    /// @dev Reverts with InsufficientRewardPool if amount exceeds balance
    /// @dev Follows checks-effects-interactions pattern: validates, updates state, then transfers ETH
    /// @dev Uses SafeTransferLib.safeTransferETH for safe ETH transfer with proper error handling
    /// @dev Emits RewardsWithdrawn event with poolId, owner, and amount
    function withdrawRewards(PoolId poolId, uint256 amount) external {
        // CHECKS: Validate all preconditions
        // Check caller is pool owner
        address owner = poolConfigs[poolId].owner;
        if (msg.sender != owner) {
            revert NotPoolOwner(msg.sender, owner);
        }

        // Check amount <= rewardPools[poolId]
        uint256 currentBalance = rewardPools[poolId];
        if (amount > currentBalance) {
            revert InsufficientRewardPool(currentBalance, amount);
        }

        // EFFECTS: Update state before external calls
        // Decrease rewardPools[poolId] by amount
        rewardPools[poolId] -= amount;

        // INTERACTIONS: External calls last
        // Transfer ETH using SafeTransferLib.safeTransferETH
        SafeTransferLib.safeTransferETH(msg.sender, amount);

        // Emit RewardsWithdrawn event
        emit RewardsWithdrawn(poolId, msg.sender, amount);
    }

    /// @notice Redeem points for ETH rewards
    /// @param poolId The pool identifier
    /// @param pointsAmount The number of points to redeem
    /// @dev Burns points and transfers ETH based on redemption rate
    /// @dev Reverts if insufficient points, insufficient reward pool balance, or below minimum threshold
    /// @dev Follows checks-effects-interactions pattern for security:
    ///      1. CHECKS: Validates all preconditions (rate set, amount > 0, meets threshold, sufficient balances)
    ///      2. EFFECTS: Updates state (burns points, decreases reward pool balance)
    ///      3. INTERACTIONS: Performs external calls (ETH transfer)
    /// @dev Uses SafeTransferLib.safeTransferETH for safe ETH transfer
    /// @dev Emits PointsRedeemed event with user, poolId, pointsAmount, ethAmount
    /// @dev Error conditions:
    ///      - RedemptionRateNotSet: Rate must be set before redemption
    ///      - ZeroRedemption: Cannot redeem zero points
    ///      - BelowMinimumRedemption: Redemption amount below minimum threshold
    ///      - InsufficientRewardPool: Reward pool has insufficient ETH
    ///      - InsufficientPoints: User has insufficient points balance
    function redeemPoints(PoolId poolId, uint256 pointsAmount) external {
        // CHECKS: Validate all preconditions in order
        
        // Get config from poolConfigs[poolId]
        PoolConfig memory config = poolConfigs[poolId];
        
        // Check config.redemptionRate > 0 (revert with RedemptionRateNotSet if zero)
        if (config.redemptionRate == 0) {
            revert RedemptionRateNotSet();
        }
        
        // Check pointsAmount > 0 (revert with ZeroRedemption if zero)
        if (pointsAmount == 0) {
            revert ZeroRedemption();
        }
        
        // Check pointsAmount >= config.minRedemption (revert with BelowMinimumRedemption if below)
        if (pointsAmount < config.minRedemption) {
            revert BelowMinimumRedemption(pointsAmount, config.minRedemption);
        }
        
        // Calculate ethAmount = pointsAmount * config.redemptionRate
        uint256 ethAmount = pointsAmount * config.redemptionRate;
        
        // Check rewardPools[poolId] >= ethAmount (revert with InsufficientRewardPool if insufficient)
        uint256 poolBalance = rewardPools[poolId];
        if (poolBalance < ethAmount) {
            revert InsufficientRewardPool(poolBalance, ethAmount);
        }
        
        // Check balanceOf(msg.sender, poolId) >= pointsAmount (revert with InsufficientPoints if insufficient)
        uint256 userBalance = this.balanceOf(msg.sender, uint256(PoolId.unwrap(poolId)));
        if (userBalance < pointsAmount) {
            revert InsufficientPoints(userBalance, pointsAmount);
        }
        
        // EFFECTS: Update state before external calls
        
        // Burn points: _burn(msg.sender, uint256(PoolId.unwrap(poolId)), pointsAmount)
        _burn(msg.sender, uint256(PoolId.unwrap(poolId)), pointsAmount);
        
        // Decrease reward pool: rewardPools[poolId] -= ethAmount
        rewardPools[poolId] -= ethAmount;
        
        // INTERACTIONS: External calls last
        
        // Transfer ETH: SafeTransferLib.safeTransferETH(msg.sender, ethAmount)
        SafeTransferLib.safeTransferETH(msg.sender, ethAmount);
        
        // Emit PointsRedeemed event with msg.sender, poolId, pointsAmount, ethAmount
        emit PointsRedeemed(msg.sender, poolId, pointsAmount, ethAmount);
    }

    /// @notice Hook called after swap execution
    /// @param key The pool key
    /// @param swapParams The swap parameters
    /// @param delta The balance delta from the swap
    /// @param hookData Additional data passed to the hook
    /// @return The selector of this function
    /// @return The amount to return (0 in this implementation)
    /// @dev Awards points to users based on ETH spent in swaps
    /// @dev Only awards points for ETH-TOKEN pools (currency0 is ETH/address(0))
    /// @dev Only awards points for zeroForOne swaps (buying TOKEN with ETH)
    /// @dev Points awarded = 20% of ETH spent
    /// @dev Requires hookData to contain encoded user address for point assignment
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        // If this is not an ETH-TOKEN pool with this hook attached, ignore
        if (!key.currency0.isAddressZero()) return (this.afterSwap.selector, 0);

        // We only mint points if user is buying TOKEN with ETH
        if (!swapParams.zeroForOne) return (this.afterSwap.selector, 0);

        // Mint points equal to 20% of the amount of ETH they spent
        // Since it's a zeroForOne swap:
        // if amountSpecified < 0:
        //      this is an "exact input for output" swap
        //      amount of ETH they spent is equal to |amountSpecified|
        // if amountSpecified > 0:
        //      this is an "exact output for input" swap
        //      amount of ETH they spent is equal to BalanceDelta.amount0()

        uint256 ethSpendAmount = uint256(int256(-delta.amount0()));
        uint256 pointsForSwap = ethSpendAmount / 5;

        // Mint the points
        _assignPoints(key.toId(), hookData, pointsForSwap);

        return (this.afterSwap.selector, 0);
    }

    /// @notice Internal function to assign points to a user
    /// @param poolId The pool identifier
    /// @param hookData The encoded user address
    /// @param points The number of points to mint
    /// @dev Decodes user address from hookData and mints points to that user
    /// @dev If hookData is empty or user is address(0), no points are assigned
    /// @dev Points are minted as ERC1155 tokens with token ID = poolId
    function _assignPoints(
        PoolId poolId,
        bytes calldata hookData,
        uint256 points
    ) internal {
        // If no hookData is passed in, no points will be assigned to anyone
        if (hookData.length == 0) return;

        // Extract user address from hookData
        address user = abi.decode(hookData, (address));

        // If there is hookData but not in the format we're expecting and user address is zero
        // nobody gets any points
        if (user == address(0)) return;

        // Mint points to the user
        uint256 poolIdUint = uint256(PoolId.unwrap(poolId));
        _mint(user, poolIdUint, points, "");
    }
}
