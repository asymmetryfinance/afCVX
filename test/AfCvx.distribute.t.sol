// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { CVX_REWARDS_POOL } from "src/interfaces/convex/ICvxRewardsPool.sol";
import { CLEVER_CVX_LOCKER, EpochUnlockInfo } from "src/interfaces/clever/ICLeverCVXLocker.sol";
import { FURNACE } from "src/interfaces/clever/IFurnace.sol";
import { BaseForkTest } from "test/utils/BaseForkTest.sol";

contract AfCvxDistributeForkTest is BaseForkTest {
    using FixedPointMathLib for uint256;

    /// @dev no CVX were deposited after the last distribution
    function test_previewDistribute_nothingDeposited() public {
        _mockCleverTotalValue(100e18, 0, 0);
        _mockStakedTotalValue(10e18);

        (uint256 cleverDepositAmount, uint256 convexStakeAmount) = afCvx.previewDistribute();
        assertEq(cleverDepositAmount, 0);
        assertEq(convexStakeAmount, 0);
    }

    /// @dev No CVX were distributed, new deposit is distributed with 80/20 ratio
    function test_previewDistribute_nothingDistributed() public {
        uint256 amount = 1000e18;
        _deposit(amount);

        (uint256 cleverDepositAmount, uint256 convexStakeAmount) = afCvx.previewDistribute();

        assertEq(cleverDepositAmount, 800e18);
        assertEq(convexStakeAmount, 200e18);
    }

    /// @dev Assert distribution is balanced, new deposit is distributed with 80/20 ratio
    function test_previewDistribute_ratioBalanced() public {
        uint256 amount = 50e18;
        _mockCleverTotalValue(800e18, 0, 0);
        _mockStakedTotalValue(200e18);
        _deposit(amount);

        (uint256 cleverDepositAmount, uint256 convexStakeAmount) = afCvx.previewDistribute();

        assertEq(cleverDepositAmount, 40e18);
        assertEq(convexStakeAmount, 10e18);
    }

    /// @dev Assert distribution is imbalanced with Clever Strategy holding more than 80% of TVL.
    ///      New deposit is distribute to correct imbalance
    function test_previewDistribute_ratioImbalanced() public {
        uint256 amount = 10e18;
        _mockCleverTotalValue(900e18, 0, 0);
        _mockStakedTotalValue(100e18);
        _deposit(amount);

        (uint256 cleverDepositAmount, uint256 convexStakeAmount) = afCvx.previewDistribute();

        assertEq(cleverDepositAmount, 0);
        assertEq(convexStakeAmount, amount);
    }

    /// @dev Unlock obligations are greater than zero but less than total deposited in Clever
    function test_previewDistribute_unlockObligationsLessThanDeposited() public {
        uint256 amount = 10e18;
        _mockCleverTotalValue(50e18, 0, 10e18);
        _mockStakedTotalValue(10e18);
        _deposit(amount);

        (uint256 cleverDepositAmount, uint256 convexStakeAmount) = afCvx.previewDistribute();

        assertEq(cleverDepositAmount, 8e18);
        assertEq(convexStakeAmount, 2e18);
    }

    /// @dev Unlock obligations are greater than total deposited in Clever
    function test_previewDistribute_unlockObligationsGreaterThanDeposited() public {
        _deposit(200e18);
        _mockCleverTotalValue(40e18, 0, 70e18);
        _mockStakedTotalValue(20e18);

        (uint256 cleverDepositAmount, uint256 convexStakeAmount) = afCvx.previewDistribute();

        assertEq(cleverDepositAmount, 182e18);
        assertEq(convexStakeAmount, 18e18);

        _mockCleverTotalValue(400e18, 0, 700e18);
        _mockStakedTotalValue(200e18);

        (cleverDepositAmount, convexStakeAmount) = afCvx.previewDistribute();

        assertEq(cleverDepositAmount, 200e18);
        assertEq(convexStakeAmount, 0);
    }

    function testFuzz_previewDistribute(uint256 deposit, uint256 total) public {
        deposit = bound(deposit, 1e20, 1e21);
        total = bound(total, 1e22, 1e23);
        uint16 cleverStrategyShareBps = afCvx.cleverStrategyShareBps();
        uint256 lockedInClever = total.mulDiv(cleverStrategyShareBps, BASIS_POINT_SCALE);
        uint256 staked = total - lockedInClever;

        _deposit(deposit);
        _mockCleverTotalValue(lockedInClever, 0, 0);
        _mockStakedTotalValue(staked);

        (uint256 cleverDepositAmount, uint256 convexStakeAmount) = afCvx.previewDistribute();
        total += (cleverDepositAmount + convexStakeAmount);
        lockedInClever += cleverDepositAmount;
        uint256 cleverShareAfter = lockedInClever.mulDiv(BASIS_POINT_SCALE, total);

        assertApproxEqAbs(cleverShareAfter, cleverStrategyShareBps, 1);
    }

    function test_distribute_depositToClever() public {
        uint256 amount1 = 25e18;
        address user1 = _createAccountWithCvx("user1", amount1);
        _deposit(user1, amount1);

        uint256 amount2 = 75e18;
        address user2 = _createAccountWithCvx("user2", amount2);
        _deposit(user2, amount2);

        vm.startPrank(operator);
        afCvx.distribute(false, 0);

        (uint256 deposited,,,,) = CLEVER_CVX_LOCKER.getUserInfo(address(cleverCvxStrategy));

        // 80% locked on Clever
        assertEq(deposited, 80e18);
        // 20% staked
        assertEq(CVX_REWARDS_POOL.balanceOf(address(afCvx)), 20e18);

        // Clever doesn't allow depositing and borrowing in the same block
        vm.roll(block.number + 1);
        cleverCvxStrategy.borrow();

        // Max borrow amount is a half of the amount locked in Clever
        (,,, uint256 borrowed,) = CLEVER_CVX_LOCKER.getUserInfo(address(cleverCvxStrategy));
        assertEq(borrowed, 40e18);

        // All borrowed clevCVX is deposited to Furnace
        (uint256 unrealised,) = FURNACE.getUserInfo(address(cleverCvxStrategy));
        assertEq(unrealised, 40e18);
    }

    function test_distribute_swap() public {
        uint256 amount = 100e18;
        _deposit(amount);

        vm.startPrank(operator);
        afCvx.distribute(true, 0);

        // 20% staked
        assertEq(CVX_REWARDS_POOL.balanceOf(address(afCvx)), 20e18);

        // nothing is locked in Clever
        (uint256 deposited,,, uint256 borrowed,) = CLEVER_CVX_LOCKER.getUserInfo(address(cleverCvxStrategy));
        assertEq(deposited, 0);
        assertEq(borrowed, 0);

        // All swapped clevCVX is deposited on Furnace
        (uint256 unrealised,) = FURNACE.getUserInfo(address(cleverCvxStrategy));
        assertGt(unrealised, 80e18);
    }
}
