// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { CVX } from "src/interfaces/convex/Constants.sol";
import { CLEVER_CVX_LOCKER } from "src/interfaces/clever/ICLeverCVXLocker.sol";
import { BaseForkTest } from "test/utils/BaseForkTest.sol";

contract AfCvxHarvestForkTest is BaseForkTest {
    function test_harvest() public {
        uint256 amount = 100 ether;
        _deposit(amount);

        assertEq(afCvx.weeklyWithdrawLimit(), 0);

        _distributeAndBorrow();

        // 1% protocolFee, 1% withdrawal fee
        _setFees(100, 100);
        // 2% of TVL can be withdrawn
        _updateWeeklyWithdrawLimit(200);

        vm.prank(operator);
        uint256 rewards = afCvx.harvest(0);

        assertEq(rewards, 0);
        // weekly withdraw limit is updated when harvesting rewards
        assertEq(afCvx.weeklyWithdrawLimit(), 2 ether);
        assertEq(afCvx.withdrawLimitNextUpdate(), block.timestamp + 1 weeks);

        skip(1 weeks);
        // simulate Furnace rewards
        _distributeFurnaceRewards(10 ether);

        (, uint256 cleverRewards) = cleverCvxStrategy.totalValue();
        assertGt(cleverRewards, 0, "no clever rewards");

        vm.prank(owner);
        rewards = afCvx.harvest(0);

        assertGt(rewards, cleverRewards, "no convex rewards");
        assertGt(CVX.balanceOf(feeCollector), 0, "fee isn't collected");
    }

    /// @dev Attacker tries to sandwich afCvx rewards harvesting with deposit and withdraw
    function test_harvest_depositWithdrawSandwichAttack() public {
        // 1% protocolFee, 1% withdrawal fee
        _setFees(100, 100);
        // 2% of TVL can be withdrawn
        _updateWeeklyWithdrawLimit(200);

        _deposit(500_000 ether);
        _distributeAndBorrow();
        skip(1 weeks);

        uint256 assetsIn = 10_000 ether;
        address attacker = _createAccountWithCvx("attacker", assetsIn);
        uint256 shares = _deposit(attacker, assetsIn);

        // simulate Furnace rewards
        _distributeFurnaceRewards(20_000 ether);
        vm.prank(operator);
        // harvested rewards transferred to afCvx increasing total assets
        afCvx.harvest(0);

        // Attacker gets less than deposited
        vm.startPrank(attacker);
        afCvx.approve(address(afCvx), shares);
        uint256 assetsOut = afCvx.redeem(shares, attacker, attacker);

        assertGt(assetsIn, assetsOut, "attacker withdrew more than deposited");
    }

    /// @dev Attacker tries to sandwich afCvx rewards harvesting with deposit and unlock
    function test_harvest_depositUnlockSandwichAttack() public {
        // 1% protocolFee, 1% withdrawal fee
        _setFees(100, 100);
        // 2% of TVL can be withdrawn
        _updateWeeklyWithdrawLimit(200);

        _deposit(1_000_000 ether);
        _distributeAndBorrow();
        skip(16 weeks);

        uint256 assetsIn = 10_000 ether;
        address attacker = _createAccountWithCvx("attacker", assetsIn);
        uint256 shares = _deposit(attacker, assetsIn);

        // simulate Furnace rewards
        _distributeFurnaceRewards(50_000 ether);
        vm.prank(operator);
        // harvested rewards transferred to afCvx increasing total assets
        afCvx.harvest(0);

        vm.startPrank(attacker);
        afCvx.approve(address(afCvx), shares);
        uint256 maxUnlock = afCvx.maxRequestUnlock(attacker);
        (uint256 unlockEpoch,) = afCvx.requestUnlock(maxUnlock, attacker, attacker);
        uint256 currentEpoch = block.timestamp / 1 weeks;
        assertEq(unlockEpoch, currentEpoch + 1, "unlock epoch isn't the next epoch");

        // unlock CVX locked in clever to fulfill the unlock request
        vm.startPrank(operator);
        cleverCvxStrategy.repay();

        vm.roll(block.number + 1);
        cleverCvxStrategy.unlock();
        vm.roll(block.number + 1);
        vm.stopPrank();

        vm.warp(currentEpoch * 1 weeks + 1 weeks);
        vm.prank(0x11E91BB6d1334585AA37D8F4fde3932C7960B938);
        CLEVER_CVX_LOCKER.processUnlockableCVX();

        // Attacker gets more than deposited since there is no withdrawal fee on unlock
        vm.prank(attacker);
        afCvx.withdrawUnlocked(attacker);

        assertGt(CVX.balanceOf(attacker), 1_0002 ether, "attacker received less than deposited");
    }
}
