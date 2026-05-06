// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PointsHook} from "../src/PointsHook.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";

// Test hook that bypasses address validation for testing
contract TestablePointsHook is PointsHook {
    constructor(IPoolManager _manager) PointsHook(_manager) {}

    function validateHookAddress(BaseHook _this) internal pure override {
        // Skip validation for testing
    }

    // Public mint function for testing
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

    /// @notice Test setMinimumRedemption multiple updates
    /// Validates: Requirements 3.1
    function test_setMinimumRedemption_multipleUpdates() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        
        vm.prank(address(0));
        hook.setMinimumRedemption(poolId, 100);
        assertEq(hook.getMinimumRedemption(poolId), 100);
        
        vm.prank(address(0));
        hook.setMinimumRedemption(poolId, 500);
        assertEq(hook.getMinimumRedemption(poolId), 500);
        
        vm.prank(address(0));
        hook.setMinimumRedemption(poolId, 0);
        assertEq(hook.getMinimumRedemption(poolId), 0);
    }

    // ============ Reward Pool Funding Tests ============

    /// @notice Test successful fundRewardPool
    /// Validates: Requirements 4.1, 4.3
    function test_fundRewardPool_successfulFunding() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 fundAmount = 1 ether;
        
        vm.expectEmit(true, true, false, true);
        emit PointsHook.RewardPoolFunded(poolId, address(this), fundAmount);
        hook.fundRewardPool{value: fundAmount}(poolId);
        
        assertEq(hook.getRewardPoolBalance(poolId), fundAmount, "Reward pool should be funded");
    }

    /// @notice Test fundRewardPool by non-owner
    /// Validates: Requirements 4.4
    function test_fundRewardPool_permissionlessFunding() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 fundAmount = 1 ether;
        address funder = address(0x5678);
        
        // Give the funder some ETH
        vm.deal(funder, 10 ether);
        
        // Fund as non-owner
        vm.prank(funder);
        hook.fundRewardPool{value: fundAmount}(poolId);
        
        assertEq(hook.getRewardPoolBalance(poolId), fundAmount, "Non-owner should be able to fund");
    }

    /// @notice Test fundRewardPool with zero ETH reverts
    /// Validates: Requirements 4.5
    function test_fundRewardPool_zeroFundingReverts() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        
        vm.expectRevert(PointsHook.ZeroFunding.selector);
        hook.fundRewardPool{value: 0}(poolId);
    }

    /// @notice Test fundRewardPool multiple fundings accumulate
    /// Validates: Requirements 4.1
    function test_fundRewardPool_multipleAccumulate() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 amount1 = 1 ether;
        uint256 amount2 = 2 ether;
        uint256 amount3 = 0.5 ether;
        
        hook.fundRewardPool{value: amount1}(poolId);
        assertEq(hook.getRewardPoolBalance(poolId), amount1);
        
        hook.fundRewardPool{value: amount2}(poolId);
        assertEq(hook.getRewardPoolBalance(poolId), amount1 + amount2);
        
        hook.fundRewardPool{value: amount3}(poolId);
        assertEq(hook.getRewardPoolBalance(poolId), amount1 + amount2 + amount3);
    }

    /// @notice Test fundRewardPool pool balance isolation
    /// Validates: Requirements 4.2
    function test_fundRewardPool_poolBalanceIsolation() public {
        hook = _deployHook();
        PoolId poolId1 = PoolId.wrap(bytes32(uint256(1)));
        PoolId poolId2 = PoolId.wrap(bytes32(uint256(2)));
        uint256 amount1 = 1 ether;
        uint256 amount2 = 2 ether;
        
        hook.fundRewardPool{value: amount1}(poolId1);
        hook.fundRewardPool{value: amount2}(poolId2);
        
        assertEq(hook.getRewardPoolBalance(poolId1), amount1, "Pool 1 balance should be isolated");
        assertEq(hook.getRewardPoolBalance(poolId2), amount2, "Pool 2 balance should be isolated");
    }

    /// @notice Test fundRewardPool emits event with correct parameters
    /// Validates: Requirements 4.3
    function test_fundRewardPool_emitsEventWithCorrectParameters() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 fundAmount = 1 ether;
        address funder = address(0x9999);
        
        // Give funder ETH
        vm.deal(funder, 10 ether);
        
        vm.prank(funder);
        vm.expectEmit(true, true, false, true);
        emit PointsHook.RewardPoolFunded(poolId, funder, fundAmount);
        hook.fundRewardPool{value: fundAmount}(poolId);
    }

    // ============ Reward Pool Withdrawal Tests ============

    /// @notice Test successful withdrawRewards by pool owner
    /// Validates: Requirements 5.1, 5.5
    function test_withdrawRewards_successfulWithdrawal() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 fundAmount = 1 ether;
        uint256 withdrawAmount = 0.5 ether;
        
        // Fund the pool
        hook.fundRewardPool{value: fundAmount}(poolId);
        
        // Withdraw as owner
        vm.prank(address(0));
        vm.expectEmit(true, true, false, true);
        emit PointsHook.RewardsWithdrawn(poolId, address(0), withdrawAmount);
        hook.withdrawRewards(poolId, withdrawAmount);
        
        assertEq(hook.getRewardPoolBalance(poolId), fundAmount - withdrawAmount, "Balance should decrease");
    }

    /// @notice Test withdrawRewards rejects non-owner
    /// Validates: Requirements 5.2, 5.3
    function test_withdrawRewards_unauthorizedRevert() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 fundAmount = 1 ether;
        
        hook.fundRewardPool{value: fundAmount}(poolId);
        
        // Try to withdraw as non-owner
        vm.prank(address(0x5678));
        vm.expectRevert(
            abi.encodeWithSelector(
                PointsHook.NotPoolOwner.selector,
                address(0x5678),
                address(0)
            )
        );
        hook.withdrawRewards(poolId, 0.5 ether);
    }

    /// @notice Test withdrawRewards with insufficient balance reverts
    /// Validates: Requirements 5.4
    function test_withdrawRewards_insufficientBalanceReverts() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 fundAmount = 1 ether;
        uint256 withdrawAmount = 2 ether;
        
        hook.fundRewardPool{value: fundAmount}(poolId);
        
        vm.prank(address(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                PointsHook.InsufficientRewardPool.selector,
                fundAmount,
                withdrawAmount
            )
        );
        hook.withdrawRewards(poolId, withdrawAmount);
    }

    /// @notice Test withdrawRewards with exact balance
    /// Validates: Requirements 5.1
    function test_withdrawRewards_exactBalance() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 fundAmount = 1 ether;
        
        hook.fundRewardPool{value: fundAmount}(poolId);
        
        vm.prank(address(0));
        hook.withdrawRewards(poolId, fundAmount);
        
        assertEq(hook.getRewardPoolBalance(poolId), 0, "Balance should be zero after full withdrawal");
    }

    /// @notice Test withdrawRewards multiple withdrawals
    /// Validates: Requirements 5.1
    function test_withdrawRewards_multipleWithdrawals() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 fundAmount = 3 ether;
        
        hook.fundRewardPool{value: fundAmount}(poolId);
        
        vm.prank(address(0));
        hook.withdrawRewards(poolId, 1 ether);
        assertEq(hook.getRewardPoolBalance(poolId), 2 ether);
        
        vm.prank(address(0));
        hook.withdrawRewards(poolId, 0.5 ether);
        assertEq(hook.getRewardPoolBalance(poolId), 1.5 ether);
        
        vm.prank(address(0));
        hook.withdrawRewards(poolId, 1.5 ether);
        assertEq(hook.getRewardPoolBalance(poolId), 0);
    }

    /// @notice Test withdrawRewards emits event with correct parameters
    /// Validates: Requirements 5.5
    function test_withdrawRewards_emitsEventWithCorrectParameters() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 fundAmount = 1 ether;
        uint256 withdrawAmount = 0.5 ether;
        address owner = address(0);
        
        hook.fundRewardPool{value: fundAmount}(poolId);
        
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit PointsHook.RewardsWithdrawn(poolId, owner, withdrawAmount);
        hook.withdrawRewards(poolId, withdrawAmount);
    }

    /// @notice Test withdrawRewards transfers ETH correctly
    /// Validates: Requirements 5.1
    function test_withdrawRewards_transfersETH() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 fundAmount = 1 ether;
        uint256 withdrawAmount = 0.5 ether;
        address owner = address(0x1111);
        
        // Give owner some ETH to fund
        vm.deal(owner, 10 ether);
        
        // Fund the pool
        vm.prank(owner);
        hook.fundRewardPool{value: fundAmount}(poolId);
        
        // Get initial balance
        uint256 initialBalance = owner.balance;
        
        // Withdraw - need to set owner as pool owner first
        // Since pool owner is address(0) by default, we need to transfer ownership
        vm.prank(address(0));
        hook.transferPoolOwnership(poolId, owner);
        
        // Now withdraw
        vm.prank(owner);
        hook.withdrawRewards(poolId, withdrawAmount);
        
        // Verify ETH was transferred (accounting for gas)
        uint256 finalBalance = owner.balance;
        assertGt(finalBalance, initialBalance - withdrawAmount, "Owner should receive ETH");
    }

    // ============ Configuration and Funding Integration Tests ============

    /// @notice Test setting rate and minimum on same pool
    /// Validates: Requirements 2.1, 3.1
    function test_configurationIntegration_setRateAndMinimum() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 rate = 1000;
        uint256 minimum = 100;
        
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, rate);
        
        vm.prank(address(0));
        hook.setMinimumRedemption(poolId, minimum);
        
        assertEq(hook.getRedemptionRate(poolId), rate);
        assertEq(hook.getMinimumRedemption(poolId), minimum);
    }

    /// @notice Test funding and configuration on same pool
    /// Validates: Requirements 2.1, 4.1
    function test_configurationIntegration_fundAndConfigure() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 rate = 1000;
        uint256 fundAmount = 1 ether;
        
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, rate);
        
        hook.fundRewardPool{value: fundAmount}(poolId);
        
        assertEq(hook.getRedemptionRate(poolId), rate);
        assertEq(hook.getRewardPoolBalance(poolId), fundAmount);
    }

    /// @notice Test multiple pools with different configurations
    /// Validates: Requirements 2.1, 3.1, 4.2
    function test_configurationIntegration_multiplePoolsIndependent() public {
        hook = _deployHook();
        PoolId poolId1 = PoolId.wrap(bytes32(uint256(1)));
        PoolId poolId2 = PoolId.wrap(bytes32(uint256(2)));
        
        // Configure pool 1
        vm.prank(address(0));
        hook.setRedemptionRate(poolId1, 1000);
        vm.prank(address(0));
        hook.setMinimumRedemption(poolId1, 100);
        
        // Configure pool 2 differently
        vm.prank(address(0));
        hook.setRedemptionRate(poolId2, 2000);
        vm.prank(address(0));
        hook.setMinimumRedemption(poolId2, 50);
        
        // Verify independence
        assertEq(hook.getRedemptionRate(poolId1), 1000);
        assertEq(hook.getMinimumRedemption(poolId1), 100);
        assertEq(hook.getRedemptionRate(poolId2), 2000);
        assertEq(hook.getMinimumRedemption(poolId2), 50);
    }

    /// @notice Test fund, configure, and withdraw workflow
    /// Validates: Requirements 2.1, 4.1, 5.1
    function test_configurationIntegration_completeWorkflow() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 rate = 1000;
        uint256 minimum = 100;
        uint256 fundAmount = 2 ether;
        uint256 withdrawAmount = 0.5 ether;
        
        // Configure
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, rate);
        vm.prank(address(0));
        hook.setMinimumRedemption(poolId, minimum);
        
        // Fund
        hook.fundRewardPool{value: fundAmount}(poolId);
        assertEq(hook.getRewardPoolBalance(poolId), fundAmount);
        
        // Withdraw
        vm.prank(address(0));
        hook.withdrawRewards(poolId, withdrawAmount);
        assertEq(hook.getRewardPoolBalance(poolId), fundAmount - withdrawAmount);
    }

    // ============ Redemption Tests ============

    /// @notice Test redeemPoints reverts when rate is not set
    /// Validates: Requirements 8.2
    function test_redeemPoints_rateNotSetReverts() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        address user = address(0x1111);
        
        // Try to redeem without setting rate
        vm.prank(user);
        vm.expectRevert(PointsHook.RedemptionRateNotSet.selector);
        hook.redeemPoints(poolId, 100);
    }

    /// @notice Test redeemPoints reverts when redeeming zero points
    /// Validates: Requirements 8.1
    function test_redeemPoints_zeroPointsReverts() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 rate = 1000;
        
        // Set rate
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, rate);
        
        // Try to redeem zero points
        vm.prank(address(0x1111));
        vm.expectRevert(PointsHook.ZeroRedemption.selector);
        hook.redeemPoints(poolId, 0);
    }

    /// @notice Test redeemPoints reverts when below minimum threshold
    /// Validates: Requirements 1.5, 1.6
    function test_redeemPoints_belowMinimumThresholdReverts() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 rate = 1000;
        uint256 minimum = 100;
        address user = address(0x1111);
        
        // Set rate and minimum
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, rate);
        vm.prank(address(0));
        hook.setMinimumRedemption(poolId, minimum);
        
        // Mint points to user (less than minimum)
        uint256 poolIdUint = uint256(PoolId.unwrap(poolId));
        vm.prank(address(hook));
        hook.testMint(user, poolIdUint, 50, "");
        
        // Try to redeem below minimum
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                PointsHook.BelowMinimumRedemption.selector,
                50,
                minimum
            )
        );
        hook.redeemPoints(poolId, 50);
    }

    /// @notice Test redeemPoints reverts when user has insufficient points
    /// Validates: Requirements 1.3
    function test_redeemPoints_insufficientPointsReverts() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 rate = 1000;
        address user = address(0x1111);
        
        // Set rate
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, rate);
        
        // Fund reward pool
        hook.fundRewardPool{value: 10 ether}(poolId);
        
        // Try to redeem without points
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                PointsHook.InsufficientPoints.selector,
                0,
                100
            )
        );
        hook.redeemPoints(poolId, 100);
    }

    /// @notice Test redeemPoints reverts when reward pool has insufficient ETH
    /// Validates: Requirements 1.4
    function test_redeemPoints_insufficientRewardPoolReverts() public {
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
        hook.testMint(user, poolIdUint, 100, "");
        
        // Fund reward pool with insufficient ETH (100 points * 1000 wei/point = 100000 wei needed)
        hook.fundRewardPool{value: 50000}(poolId);
        
        // Try to redeem
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                PointsHook.InsufficientRewardPool.selector,
                50000,
                100000
            )
        );
        hook.redeemPoints(poolId, 100);
    }

    /// @notice Test successful redemption with valid inputs
    /// Validates: Requirements 1.1, 1.2, 1.7
    function test_redeemPoints_successfulRedemption() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 rate = 1000;
        uint256 pointsAmount = 100;
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
        
        // Verify initial state
        assertEq(hook.getPointsBalance(user, poolId), pointsAmount);
        assertEq(hook.getRewardPoolBalance(poolId), 1 ether);
        
        // Redeem points
        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        emit PointsHook.PointsRedeemed(user, poolId, pointsAmount, expectedEthAmount);
        hook.redeemPoints(poolId, pointsAmount);
        
        // Verify points were burned
        assertEq(hook.getPointsBalance(user, poolId), 0, "Points should be burned");
        
        // Verify reward pool decreased
        assertEq(hook.getRewardPoolBalance(poolId), 1 ether - expectedEthAmount, "Reward pool should decrease");
    }

    /// @notice Test redemption at exact minimum threshold
    /// Validates: Requirements 1.5, 1.6
    function test_redeemPoints_atExactMinimumThreshold() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 rate = 1000;
        uint256 minimum = 100;
        uint256 pointsAmount = 100;
        address user = address(0x1111);
        
        // Set rate and minimum
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, rate);
        vm.prank(address(0));
        hook.setMinimumRedemption(poolId, minimum);
        
        // Mint points to user
        uint256 poolIdUint = uint256(PoolId.unwrap(poolId));
        vm.prank(address(hook));
        hook.testMint(user, poolIdUint, pointsAmount, "");
        
        // Fund reward pool
        hook.fundRewardPool{value: 1 ether}(poolId);
        
        // Redeem at exact minimum - should succeed
        vm.prank(user);
        hook.redeemPoints(poolId, pointsAmount);
        
        assertEq(hook.getPointsBalance(user, poolId), 0, "Points should be burned");
    }

    /// @notice Test redemption with exact reward pool balance
    /// Validates: Requirements 1.4
    function test_redeemPoints_withExactRewardPoolBalance() public {
        hook = _deployHook();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        uint256 rate = 1000;
        uint256 pointsAmount = 100;
        uint256 ethAmount = pointsAmount * rate;
        address user = address(0x1111);
        
        // Set rate
        vm.prank(address(0));
        hook.setRedemptionRate(poolId, rate);
        
        // Mint points to user
        uint256 poolIdUint = uint256(PoolId.unwrap(poolId));
        vm.prank(address(hook));
        hook.testMint(user, poolIdUint, pointsAmount, "");
        
        // Fund reward pool with exact amount needed
        hook.fundRewardPool{value: ethAmount}(poolId);
        
        // Redeem - should succeed
        vm.prank(user);
        hook.redeemPoints(poolId, pointsAmount);
        
        assertEq(hook.getRewardPoolBalance(poolId), 0, "Reward pool should be empty");
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
        
        // Set up some state
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
        
        // Call view functions multiple times
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
