// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { CVX } from "src/interfaces/convex/Constants.sol";
import { CLEVER_CVX_LOCKER, EpochUnlockInfo } from "src/interfaces/clever/ICLeverCvxLocker.sol";
import { ICleverCvxStrategy } from "src/interfaces/afCvx/ICleverCvxStrategy.sol";
import { BaseForkTest } from "test/utils/BaseForkTest.sol";
import { CVX_REWARDS_POOL } from "src/interfaces/convex/ICvxRewardsPool.sol";
import { FURNACE } from "src/interfaces/clever/IFurnace.sol";

contract AfCvxTotalAssetsForkTest is BaseForkTest {
    function test_totalAssets() public {
        uint256 assets = 100e18;
        address userA = _createAccountWithCvx("userA", assets);
        address userB = _createAccountWithCvx("userB", assets);

        // First userA deposits.
        _deposit(userA, assets);
        assertEq(afCvx.totalAssets(), assets);

        _distributeAndBorrow();
        // repay fee subtracted
        assertEq(afCvx.totalAssets(), 99.6e18);

        // Now we wait two weeks.
        skip(2 weeks);

        // Now userB deposits.
        _deposit(userB, assets);
        assertEq(afCvx.totalAssets(), 199.6e18);

        _distributeAndBorrow();
        assertEq(afCvx.totalAssets(), 199.1996e18);

        // UserA requests unlock.
        vm.startPrank(userA);
        uint256 maxUnlockA = afCvx.maxRequestUnlock(userA);
        // UserA can unlock all deposited CVX
        assertApproxEqAbs(maxUnlockA, 99.4e18, 0.001e18);
        afCvx.approve(address(afCvx), afCvx.previewRequestUnlock(maxUnlockA));
        afCvx.requestUnlock(maxUnlockA, userA, userA);
        vm.stopPrank();

        // Only assets deposited by userB considered
        assertApproxEqAbs(afCvx.totalAssets(), 100e18, 0.5e18);

        // UserB requests unlock.
        vm.startPrank(userB);
        uint256 maxUnlockB = afCvx.maxRequestUnlock(userB);

        // UserB can unlock only ~ 58 CVX
        assertApproxEqAbs(maxUnlockB, 58e18, 0.5e18);
        afCvx.approve(address(afCvx), afCvx.previewRequestUnlock(maxUnlockB));
        afCvx.requestUnlock(maxUnlockB, userB, userB);
        vm.stopPrank();

        // Total assets are approximately equal to the staked assets in Convex
        // as all assets deposited to Clever were requested to be unlocked
        assertApproxEqAbs(CVX_REWARDS_POOL.balanceOf(address(afCvx)), afCvx.totalAssets(), 1.7e18);
        // Operator repays the debt and unlocks the requested CVX
        _repayAndUnlock();
        // Again the total assets are approximately to the staked assets in Convex
        assertApproxEqAbs(CVX_REWARDS_POOL.balanceOf(address(afCvx)), afCvx.totalAssets(), 1.7e18);
    }

    function test_totalAssets_furnaceDistribution() public {
        uint256 assets = 100e18;
        address user = _createAccountWithCvx(assets);

        _deposit(user, assets);
        _distributeAndBorrow();
        assertEq(afCvx.totalAssets(), 99.6e18);

        // User requests to unlock a half of deposited assets
        vm.startPrank(user);
        uint256 unlockAmount = assets / 2;
        afCvx.approve(address(afCvx), afCvx.previewRequestUnlock(unlockAmount));
        afCvx.requestUnlock(unlockAmount, user, user);
        vm.stopPrank();

        assertEq(cleverCvxStrategy.unlockObligations(), unlockAmount);
        assertEq(afCvx.totalAssets(), 49.6e18);

        // simulate Furnace rewards
        skip(2 weeks);
        vm.roll(block.number + 1);
        _distributeFurnaceRewards(1e24);

        assertEq(afCvx.totalAssets(), 49.6e18);

        skip(2 weeks);
        vm.roll(block.number + 1);
        _distributeFurnaceRewards(1e24);

        // All funds deposited to Furnace were distributed
        (uint256 unrealised, uint256 realised) = FURNACE.getUserInfo(address(cleverCvxStrategy));
        assertEq(unrealised, 0);
        assertEq(realised, 40e18);

        // The reported Clever rewards value was decreased to keep keep total assets value accurate
        (uint256 deposited, uint256 rewards, uint256 unlockObligations) = cleverCvxStrategy.totalValue();
        assertEq(deposited, 39.6e18);
        assertEq(rewards, 40e18);
        assertEq(unlockObligations, 50e18);
        assertEq(afCvx.totalAssets(), 49.6e18);

        vm.prank(operator);
        afCvx.harvest(0);

        (deposited, rewards, unlockObligations) = cleverCvxStrategy.totalValue();
        assertEq(deposited, 39.6e18);
        assertEq(rewards, 0);
        assertEq(unlockObligations, 50e18);
        assertApproxEqAbs(afCvx.totalAssets(), 49.6e18, 0.03e18);
    }

    function test_totalAssets_dripRewards() public {
        _deposit(100e18);
        _distributeAndBorrow();

        uint256 initialTotalAssets = afCvx.totalAssets();
        assertEq(initialTotalAssets, 99.6e18);

        // simulate Clever rewards
        skip(1 weeks);
        _distributeCleverRewards(20e18);

        // totalAssets() doesn't change
        assertEq(afCvx.totalAssets(), initialTotalAssets);

        vm.prank(operator);
        (uint256 furnaceRewards, uint256 cleverRewards, uint256 convexRewards) = afCvx.harvest(0);
        (,,,,, uint256 lockedRewards) = afCvx.getAvailableAssets();

        // Rewards from each protocol is greater than zero, but totalAssets() doesn't change
        assertGt(furnaceRewards, 0);
        assertGt(cleverRewards, 0);
        assertGt(convexRewards, 0);
        assertEq(afCvx.totalAssets(), initialTotalAssets);

        // clever and convex rewards are locked
        assertEq(lockedRewards, cleverRewards + convexRewards);

        // locked rewards are distributed over 2 weeks
        skip(1 weeks);
        assertEq(afCvx.totalAssets(), initialTotalAssets + lockedRewards / 2);

        skip(1 weeks);
        assertEq(afCvx.totalAssets(), initialTotalAssets + lockedRewards);
    }
}
