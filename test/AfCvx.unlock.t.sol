// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { CVX } from "src/interfaces/convex/Constants.sol";
import { CLEVER_CVX_LOCKER, EpochUnlockInfo } from "src/interfaces/clever/ICLeverCvxLocker.sol";
import { ICleverCvxStrategy } from "src/interfaces/afCvx/ICleverCvxStrategy.sol";
import { BaseForkTest } from "test/utils/BaseForkTest.sol";

contract AfCvxUnlockForkTest is BaseForkTest {
    function test_maxTotalUnlock() public {
        uint256 assets = 100e18;
        address userA = _createAccountWithCvx("userA", assets);
        address userB = _createAccountWithCvx("userB", assets);

        _deposit(userA, assets);
        _deposit(userB, assets);
        _distributeAndBorrow();

        uint256 maxTotalUnlock = cleverCvxStrategy.maxTotalUnlock();
        // total locked in clever is 160 CVX (80 from userA and 80 from userB)
        // max unlock is less than total locked due to Clever repay fee
        assertApproxEqAbs(maxTotalUnlock, 158e18, 0.5e18);

        // userA requests to unlock 10 CVX
        uint256 unlockAmount = 10e18;
        vm.startPrank(userA);
        afCvx.approve(address(afCvx), afCvx.previewWithdraw(unlockAmount));
        afCvx.requestUnlock(unlockAmount, userA, userA);
        vm.stopPrank();
        assertEq(cleverCvxStrategy.unlockObligations(), unlockAmount);

        // total unlock amount reduced by unlock obligations
        maxTotalUnlock = cleverCvxStrategy.maxTotalUnlock();
        assertApproxEqAbs(maxTotalUnlock, 148e18, 0.5e18);

        // userA deposited 100 CVX and already requested 10 to unlock
        uint256 userAMaxUnlock = afCvx.maxRequestUnlock(userA);
        assertApproxEqAbs(userAMaxUnlock, 90e18, 0.5e18);
        // userB deposited 100 CVX
        uint256 userBMaxUnlock = afCvx.maxRequestUnlock(userB);
        assertEq(userBMaxUnlock, 99.6e18);
        // userA requests to unlock remaining 90 CVX
        vm.startPrank(userA);
        afCvx.approve(address(afCvx), afCvx.previewWithdraw(userAMaxUnlock));
        afCvx.requestUnlock(userAMaxUnlock, userA, userA);
        vm.stopPrank();

        // all CVX deposited by userA is requested to unlock
        assertApproxEqAbs(cleverCvxStrategy.unlockObligations(), 100e18, 0.5e18);
        assertEq(afCvx.maxRequestUnlock(userA), 0);

        maxTotalUnlock = cleverCvxStrategy.maxTotalUnlock();
        assertApproxEqAbs(maxTotalUnlock, 59e18, 0.5e18);
        // userB can only unlock ~ 59 CVX
        assertEq(afCvx.maxRequestUnlock(userB), maxTotalUnlock);

        // other users deposit 200 CVX
        _deposit(200e18);
        _distributeAndBorrow();

        assertApproxEqAbs(cleverCvxStrategy.maxTotalUnlock(), 237e18, 0.5e18);
        // userB can request to unlock full deposit
        assertApproxEqAbs(afCvx.maxRequestUnlock(userB), 99.3e18, 0.5e18);
    }
    
    function test_previewUnlock() public {
        uint256 assets = 100e18;
        address user = _createAccountWithCvx(assets);

        _deposit(user, assets);
        _distributeAndBorrow();

        uint256 maxUnlock = afCvx.maxRequestUnlock(user);
        uint256 preview = afCvx.previewRequestUnlock(maxUnlock);

        vm.startPrank(user);
        afCvx.approve(address(afCvx), afCvx.previewWithdraw(maxUnlock));
        (, uint256 actual) = afCvx.requestUnlock(maxUnlock, user, user);
        vm.stopPrank();

        assertEq(preview, actual);
        // the unlock amount is less than deposited due to theClever repay fee
        assertApproxEqAbs(preview, 79.5e18, 0.5e18);
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

    function testFuzz_requestUnlock_concurrentRequests(uint256 assets) public {
        assets = bound(assets, 1e17, 1e22);
        uint256 assetsA = assets;
        uint256 assetsB = assets * 2;

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
        afCvx.approve(address(afCvx), afCvx.previewRequestUnlock(firstUnlock));
        (uint256 unlockEpochA,) = afCvx.requestUnlock(firstUnlock, userA, userA);
        vm.stopPrank();
        assertEq(unlockEpochA, firstUnlockEpoch);

        // UserB also asks for a unlock equal to the first unlock.
        vm.startPrank(userB);
        afCvx.approve(address(afCvx), afCvx.previewRequestUnlock(firstUnlock));
        (uint256 unlockEpochB,) = afCvx.requestUnlock(firstUnlock, userB, userB);
        vm.stopPrank();
        assertEq(unlockEpochB, secondUnlockEpoch);
    }

    function test_withdrawUnlocked() public {
        uint256 assets = 100e18;
        address user = _createAccountWithCvx("user", assets);

        _deposit(user, assets);
        _deposit(100e18);
        assertEq(afCvx.balanceOf(user), 100e18);

        _distributeAndBorrow();

        vm.roll(block.number + 1);
        uint256 maxUnlock = afCvx.maxRequestUnlock(user);

        vm.startPrank(user);
        afCvx.approve(address(afCvx), afCvx.previewRequestUnlock(maxUnlock));
        (uint256 unlockEpoch,) = afCvx.requestUnlock(maxUnlock, user, user);
        vm.stopPrank();
        uint256 currentEpoch = block.timestamp / 1 weeks;

        // withdraw  CVX in 17 weeks
        assertEq(unlockEpoch, currentEpoch + 17);
        // CVX isn't transferred yet
        assertEq(CVX.balanceOf(user), 0);
        // afCVX is burnt
        assertEq(afCvx.balanceOf(user), 0);

        vm.startPrank(operator);
        cleverCvxStrategy.repay();
        vm.roll(block.number + 1);
        cleverCvxStrategy.unlock();
        vm.stopPrank();

        skip(17 weeks);
        vm.roll(block.number + 1);

        afCvx.withdrawUnlocked(user);
        assertEq(CVX.balanceOf(user), 99.6e18);
    }
}
