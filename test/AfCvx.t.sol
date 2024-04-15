// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { CVX } from "src/interfaces/convex/Constants.sol";
import { CLEVCVX } from "src/interfaces/clever/Constants.sol";
import { CVX_REWARDS_POOL } from "src/interfaces/convex/ICvxRewardsPool.sol";
import { CLEVER_CVX_LOCKER, EpochUnlockInfo } from "src/interfaces/clever/ICLeverCVXLocker.sol";
import { FURNACE } from "src/interfaces/clever/IFurnace.sol";
import { ICleverCvxStrategy } from "src/interfaces/afCvx/ICleverCvxStrategy.sol";
import { Zap } from "src/utils/Zap.sol";
import { BaseForkTest } from "test/utils/BaseForkTest.sol";

contract AfCvxForkTest is BaseForkTest {
    function test_deposit() public {
        uint256 assets = 10e18;
        address user = _createAccountWithCvx(assets);

        assertEq(CVX.balanceOf(user), assets);
        assertEq(CVX.balanceOf(address(afCvx)), 0);

        vm.startPrank(user);
        CVX.approve(address(afCvx), assets);
        uint256 shares = afCvx.deposit(assets, user);

        assertEq(CVX.balanceOf(user), 0);
        assertEq(CVX.balanceOf(address(afCvx)), assets);
        assertEq(afCvx.balanceOf(user), shares);
        assertEq(afCvx.totalAssets(), assets);
        assertEq(afCvx.totalSupply(), shares);
    }

    function test_mint() public {
        uint256 shares = 10e18;
        uint256 assets = afCvx.previewMint(shares);
        address user = _createAccountWithCvx(assets);

        assertEq(CVX.balanceOf(user), assets);
        assertEq(CVX.balanceOf(address(afCvx)), 0);

        vm.startPrank(user);
        CVX.approve(address(afCvx), assets);
        assets = afCvx.mint(shares, user);

        assertEq(CVX.balanceOf(user), 0);
        assertEq(CVX.balanceOf(address(afCvx)), assets);
        assertEq(afCvx.balanceOf(user), shares);
        assertEq(afCvx.totalAssets(), assets);
        assertEq(afCvx.totalSupply(), shares);
    }

    /// @dev no CVX were deposited after the last distribution
    function test_previewDistribute_nothingDeposited() public {
        _mockCleverTotalValue(100e18, 0);
        _mockStakedTotalValue(10e18, 0);

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
        _mockCleverTotalValue(800e18, 0);
        _mockStakedTotalValue(200e18, 0);
        _deposit(amount);

        (uint256 cleverDepositAmount, uint256 convexStakeAmount) = afCvx.previewDistribute();

        assertEq(cleverDepositAmount, 40e18);
        assertEq(convexStakeAmount, 10e18);
    }

    /// @dev Assert distribution is imbalanced with Clever Strategy holding more than 80% of TVL.
    ///      New deposit is distribute to correct imbalance
    function test_previewDistribute_ratioImbalanced() public {
        uint256 amount = 10e18;
        _mockCleverTotalValue(900e18, 0);
        _mockStakedTotalValue(100e18, 0);
        _deposit(amount);

        (uint256 cleverDepositAmount, uint256 convexStakeAmount) = afCvx.previewDistribute();

        assertEq(cleverDepositAmount, 0);
        assertEq(convexStakeAmount, amount);
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

    function test_harvest() public {
        uint256 amount = 100e18;
        _deposit(amount);

        assertEq(afCvx.weeklyWithdrawLimit(), 0);

        _distributeAndBorrow();

        vm.startPrank(owner);
        afCvx.setWeeklyWithdrawShare(200); // 2%;
        afCvx.setProtocolFee(100); // 1%;
        uint256 rewards = afCvx.harvest(0);
        vm.stopPrank();

        assertEq(rewards, 0);
        // weekly withdraw limit is updated when harvesting rewards
        assertEq(afCvx.weeklyWithdrawLimit(), 2e18);
        assertEq(afCvx.withdrawLimitNextUpdate(), block.timestamp + 1 weeks);

        skip(1 weeks);
        _distributeFurnaceRewards(10e18);

        (, uint256 cleverRewards) = cleverCvxStrategy.totalValue();
        assertTrue(cleverRewards > 0);

        vm.prank(owner);
        rewards = afCvx.harvest(0);

        assertTrue(rewards > cleverRewards);
        assertTrue(CVX.balanceOf(feeCollector) > 0);
    }

    function test_previewWithdraw() public {
        uint256 assets = 100e18;
        address user = _createAccountWithCvx(assets);
        uint256 shares = _deposit(user, assets);

        vm.prank(user);
        afCvx.approve(address(afCvx), shares);

        _distributeAndBorrow();

        // weekly withdraw limit is zero
        uint256 preview = afCvx.previewWithdraw(assets);
        vm.prank(user);
        uint256 actual = afCvx.withdraw(assets, user, user);
        assertEq(preview, actual);
        assertEq(preview, 0);

        _updateWeeklyWithdrawLimit(1000); // 10%
        assertEq(afCvx.weeklyWithdrawLimit(), 10e18);

        preview = afCvx.previewWithdraw(assets);
        vm.prank(user);
        actual = afCvx.withdraw(assets, user, user);
        assertEq(preview, actual);
        assertEq(preview, 10e18);
    }

    function test_withdraw() public {
        uint256 assets = 100e18;
        address user = _createAccountWithCvx(assets);

        _deposit(user, assets);
        assertEq(CVX.balanceOf(user), 0);
        assertEq(afCvx.balanceOf(user), 100e18);

        _distributeAndBorrow();

        uint256 shares = afCvx.previewWithdraw(assets);
        assertEq(shares, 0);

        vm.startPrank(owner);
        afCvx.setWeeklyWithdrawShare(200); // 2%;
        afCvx.harvest(0);
        vm.stopPrank();

        shares = afCvx.previewWithdraw(assets);
        assertEq(shares, 2e18);

        vm.startPrank(user);
        afCvx.approve(address(afCvx), shares);
        afCvx.withdraw(assets, user, user);

        assertEq(CVX.balanceOf(user), 2e18);
        assertEq(afCvx.balanceOf(user), 98e18);
    }

    function test_previewRedeem() public {
        uint256 assets = 100e18;
        address user = _createAccountWithCvx(assets);
        uint256 shares = _deposit(user, assets);

        vm.prank(user);
        afCvx.approve(address(afCvx), shares);

        _deposit(900e18);
        _distributeAndBorrow();

        // weekly withdraw limit is zero
        uint256 preview = afCvx.previewRedeem(shares);
        vm.prank(user);
        uint256 actual = afCvx.redeem(shares, user, user);
        assertEq(preview, actual);
        assertEq(preview, 0);

        _updateWeeklyWithdrawLimit(1000); // 10%
        assertEq(afCvx.weeklyWithdrawLimit(), 100e18);

        preview = afCvx.previewRedeem(shares);
        vm.prank(user);
        actual = afCvx.redeem(shares, user, user);
        assertEq(preview, actual);
        assertEq(preview, 100e18);
    }

    function test_redeem() public {
        uint256 assets = 100e18;
        address user = _createAccountWithCvx(assets);

        uint256 shares = _deposit(user, assets);
        assertEq(CVX.balanceOf(user), 0);
        assertEq(afCvx.balanceOf(user), 100e18);

        _distributeAndBorrow();

        uint256 asserts = afCvx.previewRedeem(shares);
        assertEq(asserts, 0);

        vm.startPrank(owner);
        afCvx.setWeeklyWithdrawShare(200); // 2%;
        afCvx.harvest(0);
        vm.stopPrank();

        asserts = afCvx.previewRedeem(shares);
        assertEq(asserts, 2e18);

        vm.startPrank(user);
        afCvx.approve(address(afCvx), shares);
        afCvx.redeem(shares, user, user);

        assertEq(CVX.balanceOf(user), 2e18);
        assertEq(afCvx.balanceOf(user), 98e18);
    }

    function test_previewUnlock() public {
        uint256 assets = 100e18;
        address user = _createAccountWithCvx(assets);

        uint256 shares = _deposit(user, assets);
        assertEq(afCvx.balanceOf(user), 100e18);

        _distributeAndBorrow();

        uint256 preview = afCvx.previewRequestUnlock(assets);
        vm.startPrank(user);
        afCvx.approve(address(afCvx), shares);
        (, uint256 actual) = afCvx.requestUnlock(assets, user, user);
        vm.stopPrank();

        assertEq(preview, actual);
        assertEq(preview, 80e18);
    }

    function test_withdrawUnlocked() public {
        uint256 assets = 100e18;
        address user = _createAccountWithCvx(assets);

        _deposit(user, assets);
        assertEq(afCvx.balanceOf(user), 100e18);

        _distributeAndBorrow();

        vm.roll(block.number + 1);
        uint256 assetsInClever = 80e18;
        uint256 shares = afCvx.previewRequestUnlock(assetsInClever);
        assertEq(shares, assetsInClever);

        vm.startPrank(user);
        afCvx.approve(address(afCvx), shares);
        (uint256 unlockEpoch,) = afCvx.requestUnlock(assetsInClever, user, user);
        vm.stopPrank();
        uint256 currentEpoch = block.timestamp / 1 weeks;

        // withdraw  CVX in 17 weeks
        assertEq(unlockEpoch, currentEpoch + 17);
        assertEq(CVX.balanceOf(user), 0);
        // afCVX is burnt
        assertEq(afCvx.balanceOf(user), 20e18);

        vm.prank(operator);
        // repay fails because the repay amount is greater than the amount deposited in Furnace
        // due to 1% repay fee that Clever takes
        vm.expectRevert(ICleverCvxStrategy.InsufficientFurnaceBalance.selector);
        cleverCvxStrategy.repay();

        // deposit more
        _deposit(10e18);
        vm.startPrank(operator);
        afCvx.distribute(false, 0);
        vm.roll(block.number + 1);
        cleverCvxStrategy.borrow();
        vm.roll(block.number + 1);

        // repay and unlock succeeds
        cleverCvxStrategy.repay();
        vm.roll(block.number + 1);
        cleverCvxStrategy.unlock();
        vm.stopPrank();

        vm.roll(block.number + 1);
        skip(17 weeks);
        afCvx.withdrawUnlocked(user);
        assertEq(CVX.balanceOf(user), 80e18);
    }
}
