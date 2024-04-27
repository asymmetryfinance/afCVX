// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { CVX } from "src/interfaces/convex/Constants.sol";
import { CLEVER_CVX_LOCKER, EpochUnlockInfo } from "src/interfaces/clever/ICLeverCvxLocker.sol";
import { ICleverCvxStrategy } from "src/interfaces/afCvx/ICleverCvxStrategy.sol";
import { BaseForkTest } from "test/utils/BaseForkTest.sol";

contract AfCvxUnlockForkTest is BaseForkTest {
    function test_previewUnlock() public {
        uint256 assets = 100e18;
        address user = _createAccountWithCvx(assets);

        _deposit(user, assets);
        assertEq(afCvx.balanceOf(user), 100e18);

        _distributeAndBorrow();

        uint256 maxUnlock = afCvx.maxRequestUnlock(user);
        uint256 preview = afCvx.previewRequestUnlock(maxUnlock);
        vm.startPrank(user);
        afCvx.approve(address(afCvx), afCvx.previewWithdraw(maxUnlock));
        (, uint256 actual) = afCvx.requestUnlock(maxUnlock, user, user);
        vm.stopPrank();

        assertEq(preview, actual);
        assertEq(preview, 80e18);
    }

    function test_requestUnlock_concurrentRequests() public {
        uint256 assets = 100e18;
        address userA = _createAccountWithCvx("userA", assets);
        address userB = _createAccountWithCvx("userB", assets);
        address userC = _createAccountWithCvx("userC", assets * 10);

        // First userA deposits.
        _deposit(userA, assets);
        _distributeAndBorrow();

        // Now we wait two week.
        skip(2 weeks);
        vm.roll(block.number + 1);

        // Now userB and userC deposit.
        _deposit(userB, assets);
        _deposit(userC, assets * 10);
        _distributeAndBorrow();

        // We now have two locks.
        (EpochUnlockInfo[] memory locks,) = CLEVER_CVX_LOCKER.getUserLocks(address(cleverCvxStrategy));
        assertEq(locks.length, 2);

        // locks are 2 weeks apart
        uint256 firstUnlockEpoch = locks[0].unlockEpoch;
        uint256 secondUnlockEpoch = locks[1].unlockEpoch;
        assertEq(secondUnlockEpoch, firstUnlockEpoch + 2);

        uint256 firstUnlock = locks[0].pendingUnlock;

        // UserA requests a unlock equal to 100% of the first unlock.
        vm.startPrank(userA);
        afCvx.approve(address(afCvx), afCvx.previewWithdraw(firstUnlock));
        (uint256 unlockEpochA,) = afCvx.requestUnlock(firstUnlock, userA, userA);
        vm.stopPrank();
        // userA can withdraw unlocked at the first epoch
        assertEq(unlockEpochA, firstUnlockEpoch);
        // unlock obligations updated
        assertEq(cleverCvxStrategy.unlockObligations(), firstUnlock);

        // UserB also asks for a unlock equal to the first unlock.
        vm.startPrank(userB);
        afCvx.approve(address(afCvx), afCvx.previewWithdraw(firstUnlock));
        (uint256 unlockEpochB,) = afCvx.requestUnlock(firstUnlock, userB, userB);
        vm.stopPrank();
        // userB can withdraw unlocked at the second epoch
        assertEq(unlockEpochB, secondUnlockEpoch);
        // unlock obligations updated
        assertEq(cleverCvxStrategy.unlockObligations(), firstUnlock * 2);

        ICleverCvxStrategy.UnlockRequest[] memory unlocksA = cleverCvxStrategy.getRequestedUnlocks(userA);
        assertEq(unlocksA.length, 1);
        assertEq(unlocksA[0].unlockEpoch, unlockEpochA);
        assertEq(unlocksA[0].unlockAmount, firstUnlock);

        ICleverCvxStrategy.UnlockRequest[] memory unlocksB = cleverCvxStrategy.getRequestedUnlocks(userB);
        assertEq(unlocksB.length, 1);
        assertEq(unlocksB[0].unlockEpoch, unlockEpochB);
        assertEq(unlocksB[0].unlockAmount, firstUnlock);
    }

    function testFuzz_requestUnlock_concurrentRequests(uint256 assetsA, uint256 assetsB) public {
        assetsA = bound(assetsA, 1e16, 1e22);
        assetsB = bound(assetsB, 1e16, 1e22);
        vm.assume(assetsA < assetsB);

        address userA = _createAccountWithCvx("userA", assetsA);
        address userB = _createAccountWithCvx("userB", assetsB);

        // First userA deposits.
        _deposit(userA, assetsA);
        _distributeAndBorrow();

        // Now we wait two week.
        skip(3 weeks);
        vm.roll(block.number + 1);

        // Now userB deposits.
        _deposit(userB, assetsB);
        _distributeAndBorrow();

        // We now have two locks.
        (EpochUnlockInfo[] memory locks,) = CLEVER_CVX_LOCKER.getUserLocks(address(cleverCvxStrategy));
        assertEq(locks.length, 2);

        uint256 firstUnlockEpoch = locks[0].unlockEpoch;
        uint256 secondUnlockEpoch = locks[1].unlockEpoch;
        assertEq(secondUnlockEpoch, firstUnlockEpoch + 3);

        uint256 firstUnlock = locks[0].pendingUnlock;

        // UserA requests a unlock equal to 100% of the first unlock.
        vm.startPrank(userA);
        afCvx.approve(address(afCvx), afCvx.previewWithdraw(firstUnlock));
        (uint256 unlockEpochA,) = afCvx.requestUnlock(firstUnlock, userA, userA);
        vm.stopPrank();
        assertEq(unlockEpochA, firstUnlockEpoch);

        // UserB also asks for a unlock equal to the first unlock.
        vm.startPrank(userB);
        afCvx.approve(address(afCvx), afCvx.previewWithdraw(firstUnlock));
        (uint256 unlockEpochB,) = afCvx.requestUnlock(firstUnlock, userB, userB);
        vm.stopPrank();
        assertEq(unlockEpochB, secondUnlockEpoch);
    }

    function test_withdrawUnlocked() public {
        uint256 assets = 100e18;
        address user = _createAccountWithCvx(assets);

        _deposit(user, assets);
        assertEq(afCvx.balanceOf(user), 100e18);

        _distributeAndBorrow();

        vm.roll(block.number + 1);
        uint256 maxUnlock = afCvx.maxRequestUnlock(user);

        vm.startPrank(user);
        afCvx.approve(address(afCvx), afCvx.previewWithdraw(maxUnlock));
        (uint256 unlockEpoch,) = afCvx.requestUnlock(maxUnlock, user, user);
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

        skip(17 weeks);
        vm.roll(block.number + 1);

        afCvx.withdrawUnlocked(user);
        assertEq(CVX.balanceOf(user), 80e18);
    }
}
