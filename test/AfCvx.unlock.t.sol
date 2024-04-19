// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { CVX } from "src/interfaces/convex/Constants.sol";
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
