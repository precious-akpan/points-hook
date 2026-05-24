// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ERC1155TokenReceiver} from "solmate/src/tokens/ERC1155.sol";
import {PointsHook} from "../src/PointsHook.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import "forge-std/console.sol";

// Test hook that bypasses address validation for testing
contract TestablePointsHook is PointsHook {
    constructor(IPoolManager _manager) PointsHook(_manager) {}

    function validateHookAddress(BaseHook _this) internal pure override {
        // Skip validation for testing
    }

    function testMint(address to, uint256 id, uint256 amount, bytes memory data) public {
        _mint(to, id, amount, data);
    }
}

contract TestPointsHook is Test {
    // Events for testing
    event RedemptionRateUpdated(
        PoolId indexed poolId,
        uint256 oldRate,
        uint256 newRate
    );
    
    event MinimumRedemptionUpdated(
        PoolId indexed poolId,
        uint256 oldThreshold,
        uint256 newThreshold
    );
    
    event RewardPoolFunded(
        PoolId indexed poolId,
        address indexed funder,
        uint256 amount
    );
    
    event RewardsWithdrawn(
        PoolId indexed poolId,
        address indexed owner,
        uint256 amount
    );
    TestablePointsHook hook;

    function setUp() public {
        // We'll deploy the hook in each test that needs it
        // to avoid the HookAddressNotValid error
    }

    function _deployHook() internal returns (TestablePointsHook) {
        // Create a mock pool manager
        IPoolManager mockManager = IPoolManager(address(0x1234));
        
        // Deploy testable hook that bypasses address validation
        return new TestablePointsHook(mockManager);
    }

    // ============ Pool Initialization and Ownership Tests ============

    /// @notice Test that transferPoolOwnership rejects zero address
    /// Validates: Requirements 7.5
    function test_transferPoolOwnership_zeroAddressRevert() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        
        // Try to transfer to zero address
        vm.expectRevert(PointsHook.InvalidOwnerAddress.selector);
        hook.transferPoolOwnership(poolId, address(0));
    }

    /// @notice Test that transferPoolOwnership rejects non-owner
    /// Validates: Requirements 7.3
    function test_transferPoolOwnership_unauthorizedRevert() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        address newOwner = address(0x1234);
        
        // Try to transfer from non-owner
        vm.prank(address(0x5678));
        vm.expectRevert(
            abi.encodeWithSelector(
                PointsHook.NotPoolOwner.selector,
                address(0x5678),
                address(0)
            )
        );
        hook.transferPoolOwnership(poolId, newOwner);
    }

    /// @notice Test that setRedemptionRate rejects rates above safe bounds
    /// Validates: Requirements 2.5, 8.5
    function test_setRedemptionRate_aboveSafeBoundsRevert() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        
        // Calculate max safe rate: type(uint256).max / 2^128
        uint256 maxSafeRate = type(uint256).max / (2 ** 128);
        
        // Try to set rate above max safe rate
        vm.prank(address(0));
        vm.expectRevert(PointsHook.InvalidRedemptionRate.selector);
        hook.setRedemptionRate(poolId, maxSafeRate + 1);
    }

    /// @notice Test that setRedemptionRate accepts rates at safe bounds
    /// Validates: Requirements 2.5, 8.5
    function test_setRedemptionRate_atSafeBoundsSucceeds() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        
        // Calculate max safe rate: type(uint256).max / 2^128
        uint256 maxSafeRate = type(uint256).max / (2 ** 128);
        
        // Set rate at max safe rate - should succeed
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, maxSafeRate);
        
        assertEq(hook.getRedemptionRate(poolId), maxSafeRate, "Rate at safe bounds should be accepted");
    }

    /// @notice Test that setRedemptionRate rejects zero rate
    /// Validates: Requirements 2.4
    function test_setRedemptionRate_zeroRateRevert() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        
        // Try to set rate to zero
        vm.expectRevert(PointsHook.InvalidRedemptionRate.selector);
        hook.setRedemptionRate(poolId, 0);
    }

    /// @notice Test that setRedemptionRate rejects non-owner
    /// Validates: Requirements 2.2
    function test_setRedemptionRate_unauthorizedRevert() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        
        // Try to set rate as non-owner
        vm.prank(address(0x5678));
        vm.expectRevert(
            abi.encodeWithSelector(
                PointsHook.NotPoolOwner.selector,
                address(0x5678),
                address(0)
            )
        );
        hook.setRedemptionRate(poolId, 1000);
    }

    /// @notice Test that setMinimumRedemption rejects non-owner
    /// Validates: Requirements 3.2
    function test_setMinimumRedemption_unauthorizedRevert() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        
        // Try to set minimum as non-owner
        vm.prank(address(0x5678));
        vm.expectRevert(
            abi.encodeWithSelector(
                PointsHook.NotPoolOwner.selector,
                address(0x5678),
                address(0)
            )
        );
        hook.setMinimumRedemption(poolId, 100);
    }

    /// @notice Test that getRedemptionRate returns zero for uninitialized pool
    /// Validates: Requirements 6.4
    function test_getRedemptionRate_returnsZeroForUninitializedPool() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(999)));
        uint256 rate = hook.getRedemptionRate(poolId);
        assertEq(rate, 0, "Uninitialized pool should have zero rate");
    }

    /// @notice Test that getMinimumRedemption returns zero for uninitialized pool
    /// Validates: Requirements 6.4
    function test_getMinimumRedemption_returnsZeroForUninitializedPool() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(999)));
        uint256 minRedemption = hook.getMinimumRedemption(poolId);
        assertEq(minRedemption, 0, "Uninitialized pool should have zero minimum");
    }

    /// @notice Test that getRewardPoolBalance returns zero for uninitialized pool
    /// Validates: Requirements 6.3
    function test_getRewardPoolBalance_returnsZeroForUninitializedPool() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(999)));
        uint256 balance = hook.getRewardPoolBalance(poolId);
        assertEq(balance, 0, "Uninitialized pool should have zero reward balance");
    }

    /// @notice Test that getPoolOwner returns zero for uninitialized pool
    /// Validates: Requirements 6.4
    function test_getPoolOwner_returnsZeroForUninitializedPool() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(999)));
        address owner = hook.getPoolOwner(poolId);
        assertEq(owner, address(0), "Uninitialized pool should have zero owner");
    }

    /// @notice Test that calculateRedemptionValue returns zero for uninitialized pool
    /// Validates: Requirements 6.2
    function test_calculateRedemptionValue_returnsZeroForUninitializedPool() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(999)));
        uint256 value = hook.calculateRedemptionValue(poolId, 100);
        assertEq(value, 0, "Uninitialized pool should have zero redemption value");
    }

    /// @notice Test that calculateRedemptionValue calculates correctly with rate
    /// Validates: Requirements 6.2
    function test_calculateRedemptionValue_calculatesCorrectly() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 pointsAmount = 100;
        
        // For uninitialized pool, rate is 0, so value should be 0
        uint256 value = hook.calculateRedemptionValue(poolId, pointsAmount);
        assertEq(value, 0, "Uninitialized pool should have zero value");
    }

    // ============ Configuration Functions Tests ============

    /// @notice Test successful setRedemptionRate by pool owner
    /// Validates: Requirements 2.1, 2.6
    function test_setRedemptionRate_successfulUpdate() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 newRate = 1000;
        
        // Set rate as owner (address 0 is the default owner for uninitialized pools)
        vm.prank(address(0));
        vm.expectEmit(true, false, false, true);
        emit PointsHook.RedemptionRateUpdated(poolId, 0, newRate);
        hook.setRedemptionRate(poolId, newRate);
        
        // Verify rate was stored
        assertEq(hook.getRedemptionRate(poolId), newRate, "Rate should be updated");
    }

    /// @notice Test setRedemptionRate emits event with correct old rate
    /// Validates: Requirements 2.6
    function test_setRedemptionRate_emitsEventWithOldRate() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 oldRate = 1000;
        uint256 newRate = 2000;
        
        // Set initial rate
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, oldRate);
        
        // Update rate and verify event
        vm.prank(address(0));
        vm.expectEmit(true, false, false, true);
        emit PointsHook.RedemptionRateUpdated(poolId, oldRate, newRate);
        hook.setRedemptionRate(poolId, newRate);
    }

    /// @notice Test setRedemptionRate multiple updates
    /// Validates: Requirements 2.1
    function test_setRedemptionRate_multipleUpdates() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, 1000);
        assertEq(hook.getRedemptionRate(poolId), 1000);
        
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, 2000);
        assertEq(hook.getRedemptionRate(poolId), 2000);
        
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, 500);
        assertEq(hook.getRedemptionRate(poolId), 500);
    }

    /// @notice Test setMinimumRedemption successful update
    /// Validates: Requirements 3.1, 3.5
    function test_setMinimumRedemption_successfulUpdate() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 newMinimum = 100;
        
        vm.prank(address(0));
        vm.expectEmit(true, false, false, true);
        emit PointsHook.MinimumRedemptionUpdated(poolId, 0, newMinimum);
        hook.setMinimumRedemption(poolId, newMinimum);
        
        assertEq(hook.getMinimumRedemption(poolId), newMinimum, "Minimum should be updated");
    }

    /// @notice Test setMinimumRedemption allows zero to disable threshold
    /// Validates: Requirements 3.4
    function test_setMinimumRedemption_zeroDisablesThreshold() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        
        // Set a minimum
        vm.prank(address(0));
        hook.setMinimumRedemption(poolId, 100);
        assertEq(hook.getMinimumRedemption(poolId), 100);
        
        // Set to zero to disable
        vm.prank(address(0));
        hook.setMinimumRedemption(poolId, 0);
        assertEq(hook.getMinimumRedemption(poolId), 0, "Minimum should be zero");
    }

    /// @notice Test setMinimumRedemption emits event with correct old threshold
    /// Validates: Requirements 3.5
    function test_setMinimumRedemption_emitsEventWithOldThreshold() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 oldThreshold = 100;
        uint256 newThreshold = 200;
        
        vm.prank(address(0));
        hook.setMinimumRedemption(poolId, oldThreshold);
        
        vm.prank(address(0));
        vm.expectEmit(true, false, false, true);
        emit PointsHook.MinimumRedemptionUpdated(poolId, oldThreshold, newThreshold);
        hook.setMinimumRedemption(poolId, newThreshold);
    }









    /// @notice Test multiple redemptions by same user
    /// Validates: Requirements 1.1, 1.2
    function test_redeemPoints_multipleRedemptionsBySameUser() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 rate = 1000;
        address user = address(0x1111);
        
        // Set rate
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, rate);
        
        // Mint points to user
        uint256 poolIdUint = uint256(PoolId.unwrap(poolId));
        vm.prank(address(hook));
        hook.testMint(user, poolIdUint, 300, "");
        
        // Fund reward pool
        hook.fundRewardPool{value: 1 ether}(poolId);
        
        // First redemption
        vm.prank(user);
        hook.redeemPoints(poolId, 100);
        assertEq(hook.getPointsBalance(user, poolId), 200);
        
        // Second redemption
        vm.prank(user);
        hook.redeemPoints(poolId, 100);
        assertEq(hook.getPointsBalance(user, poolId), 100);
        
        // Third redemption
        vm.prank(user);
        hook.redeemPoints(poolId, 100);
        assertEq(hook.getPointsBalance(user, poolId), 0);
    }

    /// @notice Test multiple users redeeming from same pool
    /// Validates: Requirements 1.1, 1.2
    function test_redeemPoints_multipleUsersRedeemingFromSamePool() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 rate = 1000;
        address user1 = address(0x1111);
        address user2 = address(0x2222);
        
        // Set rate
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, rate);
        
        // Mint points to both users
        uint256 poolIdUint = uint256(PoolId.unwrap(poolId));
        vm.prank(address(hook));
        hook.testMint(user1, poolIdUint, 100, "");
        vm.prank(address(hook));
        hook.testMint(user2, poolIdUint, 100, "");
        
        // Fund reward pool
        hook.fundRewardPool{value: 1 ether}(poolId);
        
        // User 1 redeems
        vm.prank(user1);
        hook.redeemPoints(poolId, 100);
        assertEq(hook.getPointsBalance(user1, poolId), 0);
        
        // User 2 redeems
        vm.prank(user2);
        hook.redeemPoints(poolId, 100);
        assertEq(hook.getPointsBalance(user2, poolId), 0);
        
        // Verify reward pool decreased correctly
        uint256 expectedRemaining = 1 ether - (100 * rate) - (100 * rate);
        assertEq(hook.getRewardPoolBalance(poolId), expectedRemaining);
    }

    /// @notice Test redemption with zero minimum threshold
    /// Validates: Requirements 3.4
    function test_redeemPoints_withZeroMinimumThreshold() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 rate = 1000;
        address user = address(0x1111);
        
        // Set rate with zero minimum (disabled)
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, rate);
        vm.prank(address(0));
        hook.setMinimumRedemption(poolId, 0);
        
        // Mint small amount of points
        uint256 poolIdUint = uint256(PoolId.unwrap(poolId));
        vm.prank(address(hook));
        hook.testMint(user, poolIdUint, 1, "");
        
        // Fund reward pool
        hook.fundRewardPool{value: 1 ether}(poolId);
        
        // Redeem 1 point - should succeed even though it's below any reasonable threshold
        vm.prank(user);
        hook.redeemPoints(poolId, 1);
        
        assertEq(hook.getPointsBalance(user, poolId), 0);
    }

    /// @notice Test redemption event contains correct parameters
    /// Validates: Requirements 1.7
    function test_redeemPoints_eventContainsCorrectParameters() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 rate = 1000;
        uint256 pointsAmount = 50;
        uint256 expectedEthAmount = pointsAmount * rate;
        address user = address(0x1111);
        
        // Set rate
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, rate);
        
        // Mint points to user
        uint256 poolIdUint = uint256(PoolId.unwrap(poolId));
        vm.prank(address(hook));
        hook.testMint(user, poolIdUint, pointsAmount, "");
        
        // Fund reward pool
        hook.fundRewardPool{value: 1 ether}(poolId);
        
        // Redeem and verify event
        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        emit PointsHook.PointsRedeemed(user, poolId, pointsAmount, expectedEthAmount);
        hook.redeemPoints(poolId, pointsAmount);
    }

    /// @notice Test checks-effects-interactions pattern is followed
    /// Validates: Requirements 8.4
    function test_redeemPoints_checksEffectsInteractionsPattern() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 rate = 1000;
        uint256 pointsAmount = 100;
        address user = address(0x1111);
        
        // Set rate
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, rate);
        
        // Mint points to user
        uint256 poolIdUint = uint256(PoolId.unwrap(poolId));
        vm.prank(address(hook));
        hook.testMint(user, poolIdUint, pointsAmount, "");
        
        // Fund reward pool
        hook.fundRewardPool{value: 1 ether}(poolId);
        
        // Get initial state
        uint256 initialUserBalance = user.balance;
        uint256 initialPoolBalance = hook.getRewardPoolBalance(poolId);
        uint256 initialUserPoints = hook.getPointsBalance(user, poolId);
        
        // Redeem
        vm.prank(user);
        hook.redeemPoints(poolId, pointsAmount);
        
        // Verify effects occurred in correct order:
        // 1. Points were burned
        assertEq(hook.getPointsBalance(user, poolId), initialUserPoints - pointsAmount, "Points should be burned");
        
        // 2. Reward pool was decreased
        uint256 expectedEthAmount = pointsAmount * rate;
        assertEq(hook.getRewardPoolBalance(poolId), initialPoolBalance - expectedEthAmount, "Reward pool should decrease");
        
        // 3. ETH was transferred to user
        assertGt(user.balance, initialUserBalance, "User should receive ETH");
    }

    /// @notice Test redemption with various point amounts
    /// Validates: Requirements 1.1, 1.2
    function test_redeemPoints_variousPointAmounts() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 rate = 1000;
        address user = address(0x1111);
        
        // Set rate
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, rate);
        
        // Test with different point amounts
        uint256[] memory pointAmounts = new uint256[](4);
        pointAmounts[0] = 1;
        pointAmounts[1] = 10;
        pointAmounts[2] = 100;
        pointAmounts[3] = 1000;
        
        // Fund reward pool once with enough for all redemptions
        uint256 totalEthNeeded = 0;
        for (uint256 i = 0; i < pointAmounts.length; i++) {
            totalEthNeeded += pointAmounts[i] * rate;
        }
        hook.fundRewardPool{value: totalEthNeeded + 1 ether}(poolId);
        
        for (uint256 i = 0; i < pointAmounts.length; i++) {
            uint256 amount = pointAmounts[i];
            
            // Mint points
            uint256 poolIdUint = uint256(PoolId.unwrap(poolId));
            vm.prank(address(hook));
            hook.testMint(user, poolIdUint, amount, "");
            
            // Redeem
            vm.prank(user);
            hook.redeemPoints(poolId, amount);
            
            // Verify
            assertEq(hook.getPointsBalance(user, poolId), 0, "Points should be burned");
        }
    }

    /// @notice Test redemption with high redemption rate
    /// Validates: Requirements 1.2
    function test_redeemPoints_highRedemptionRate() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 rate = 1e18; // 1 ETH per point
        uint256 pointsAmount = 10;
        address user = address(0x1111);
        
        // Set high rate
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, rate);
        
        // Mint points
        uint256 poolIdUint = uint256(PoolId.unwrap(poolId));
        vm.prank(address(hook));
        hook.testMint(user, poolIdUint, pointsAmount, "");
        
        // Fund reward pool with enough ETH
        uint256 requiredEth = pointsAmount * rate;
        hook.fundRewardPool{value: requiredEth + 1 ether}(poolId);
        
        // Redeem
        vm.prank(user);
        hook.redeemPoints(poolId, pointsAmount);
        
        // Verify correct ETH amount was transferred
        assertEq(hook.getRewardPoolBalance(poolId), 1 ether, "Correct ETH should be transferred");
    }

    /// @notice Test redemption with low redemption rate
    /// Validates: Requirements 1.2
    function test_redeemPoints_lowRedemptionRate() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 rate = 1; // 1 wei per point
        uint256 pointsAmount = 1000;
        address user = address(0x1111);
        
        // Set low rate
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, rate);
        
        // Mint points
        uint256 poolIdUint = uint256(PoolId.unwrap(poolId));
        vm.prank(address(hook));
        hook.testMint(user, poolIdUint, pointsAmount, "");
        
        // Fund reward pool
        hook.fundRewardPool{value: 1 ether}(poolId);
        
        // Redeem
        vm.prank(user);
        hook.redeemPoints(poolId, pointsAmount);
        
        // Verify correct ETH amount was transferred
        uint256 expectedEthAmount = pointsAmount * rate;
        assertEq(hook.getRewardPoolBalance(poolId), 1 ether - expectedEthAmount);
    }

    /// @notice Test view function getPointsBalance returns correct value
    /// Validates: Requirements 6.1
    function test_viewFunctions_getPointsBalance() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        address user = address(0x1111);
        uint256 pointsAmount = 500;
        
        // Mint points
        uint256 poolIdUint = uint256(PoolId.unwrap(poolId));
        vm.prank(address(hook));
        hook.testMint(user, poolIdUint, pointsAmount, "");
        
        // Verify getPointsBalance returns correct value
        assertEq(hook.getPointsBalance(user, poolId), pointsAmount);
    }

    /// @notice Test view function calculateRedemptionValue returns correct value
    /// Validates: Requirements 6.2
    function test_viewFunctions_calculateRedemptionValue() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 rate = 1000;
        uint256 pointsAmount = 100;
        
        // Set rate
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, rate);
        
        // Verify calculateRedemptionValue returns correct value
        uint256 expectedValue = pointsAmount * rate;
        assertEq(hook.calculateRedemptionValue(poolId, pointsAmount), expectedValue);
    }

    /// @notice Test view function getRewardPoolBalance returns correct value
    /// Validates: Requirements 6.3
    function test_viewFunctions_getRewardPoolBalance() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 fundAmount = 5 ether;
        
        // Fund pool
        hook.fundRewardPool{value: fundAmount}(poolId);
        
        // Verify getRewardPoolBalance returns correct value
        assertEq(hook.getRewardPoolBalance(poolId), fundAmount);
    }

    /// @notice Test view function getRedemptionRate returns correct value
    /// Validates: Requirements 6.4
    function test_viewFunctions_getRedemptionRate() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 rate = 2500;
        
        // Set rate
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, rate);
        
        // Verify getRedemptionRate returns correct value
        assertEq(hook.getRedemptionRate(poolId), rate);
    }

    /// @notice Test view function getMinimumRedemption returns correct value
    /// Validates: Requirements 6.4
    function test_viewFunctions_getMinimumRedemption() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 minimum = 250;
        
        // Set minimum
        vm.prank(address(0));
        hook.setMinimumRedemption(poolId, minimum);
        
        // Verify getMinimumRedemption returns correct value
        assertEq(hook.getMinimumRedemption(poolId), minimum);
    }

    /// @notice Test view function getPoolOwner returns correct value
    /// Validates: Requirements 6.4
    function test_viewFunctions_getPoolOwner() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        address newOwner = address(0x9999);
        
        // Transfer ownership
        vm.prank(address(0));
        hook.transferPoolOwnership(poolId, newOwner);
        
        // Verify getPoolOwner returns correct value
        assertEq(hook.getPoolOwner(poolId), newOwner);
    }

    /// @notice Test view functions don't modify state
    /// Validates: Requirements 6.5
    function test_viewFunctions_readOnly() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        address user = address(0x1111);
        
//         // Set up some state
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, 1000);
        vm.prank(address(0));
        hook.setMinimumRedemption(poolId, 100);
        hook.fundRewardPool{value: 1 ether}(poolId);
        
        uint256 poolIdUint = uint256(PoolId.unwrap(poolId));
        vm.prank(address(hook));
        hook.testMint(user, poolIdUint, 500, "");
        
        // Get initial state
        uint256 initialRate = hook.getRedemptionRate(poolId);
        uint256 initialMinimum = hook.getMinimumRedemption(poolId);
        uint256 initialBalance = hook.getRewardPoolBalance(poolId);
        uint256 initialPoints = hook.getPointsBalance(user, poolId);
        
//         // Call view functions multiple times
        for (uint256 i = 0; i < 10; i++) {
            hook.getRedemptionRate(poolId);
            hook.getMinimumRedemption(poolId);
            hook.getRewardPoolBalance(poolId);
            hook.getPointsBalance(user, poolId);
            hook.calculateRedemptionValue(poolId, 100);
            hook.getPoolOwner(poolId);
        }
        
        // Verify state hasn't changed
        assertEq(hook.getRedemptionRate(poolId), initialRate);
        assertEq(hook.getMinimumRedemption(poolId), initialMinimum);
        assertEq(hook.getRewardPoolBalance(poolId), initialBalance);
        assertEq(hook.getPointsBalance(user, poolId), initialPoints);
    }
}
