// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { CVX } from "src/interfaces/convex/Constants.sol";
import { CLEVER_CVX_LOCKER } from "src/interfaces/clever/ICLeverCVXLocker.sol";
import { BaseForkTest } from "test/utils/BaseForkTest.sol";

contract AfCvxHarvestForkTest is BaseForkTest {
    function test_harvest() public {
        uint256 amount = 100e18;
        _deposit(amount);

        assertEq(afCvx.weeklyWithdrawalLimit(), 0);

        _distributeAndBorrow();

        // 1% protocolFee, 1% withdrawal fee
        _setFees(100, 100);
        // 2% of TVL can be withdrawn
        _updateWeeklyWithdrawalLimit(200);

        vm.prank(operator);
        (uint256 furnaceRewards, uint256 cleverRewards, uint256 convexStakedRewards) = afCvx.harvest(0);

        assertEq(furnaceRewards, 0);
        assertEq(cleverRewards, 0);
        assertEq(convexStakedRewards, 0);
        // weekly withdraw limit is updated when harvesting rewards
        assertEq(afCvx.weeklyWithdrawalLimit(), 1.992e18);
        assertEq(afCvx.withdrawalLimitNextUpdate(), block.timestamp + 1 weeks);

        skip(1 weeks);
        // simulate Clever rewards
        _distributeCleverRewards(2e18);
        // simulate Furnace rewards
        _distributeFurnaceRewards(10e18);

        (, uint256 rewards,) = cleverCvxStrategy.totalValue();
        assertGt(rewards, 0, "no rewards");

        uint256 totalAssetsBefore = afCvx.totalAssets();
        vm.prank(operator);
        (furnaceRewards, cleverRewards, convexStakedRewards) = afCvx.harvest(0);
        uint256 totalAssetsAfter = afCvx.totalAssets();
        (,,,, uint256 unlockedRewards, uint256 lockedRewards) = afCvx.getAvailableAssets();
        uint256 initialLockedRewards = lockedRewards;

        // TVL should not change after harvest as rewards are distributed over time
        assertEq(totalAssetsAfter, totalAssetsBefore, "TVL changed after harvest");
        assertGt(rewards, furnaceRewards, "no convex rewards");
        assertGt(CVX.balanceOf(feeCollector), 0, "fee isn't collected");
        assertEq(lockedRewards, cleverRewards + convexStakedRewards, "invalid locked rewards");
        assertEq(unlockedRewards, 0, "unlock rewards greater than zero");

        skip(1 weeks);

        (,,,, unlockedRewards, lockedRewards) = afCvx.getAvailableAssets();
        assertEq(unlockedRewards, initialLockedRewards / 2);
        assertEq(lockedRewards, initialLockedRewards / 2);

        skip(1 weeks);

        (,,,, unlockedRewards, lockedRewards) = afCvx.getAvailableAssets();
        assertEq(unlockedRewards, initialLockedRewards);
        assertEq(lockedRewards, 0);
    }
}
