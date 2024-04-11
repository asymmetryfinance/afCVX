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
        uint256 assets = 1000e18;
        _deposit(assets);

        (uint256 cleverDepositAmount, uint256 convexStakeAmount) = afCvx.previewDistribute();

        assertEq(cleverDepositAmount, 800e18);
        assertEq(convexStakeAmount, 200e18);
    }

    /// @dev Assert distribution is balanced, new deposit is distributed with 80/20 ratio
    function test_previewDistribute_ratioBalanced() public {
        uint256 assets = 50e18;
        _mockCleverTotalValue(800e18, 0);
        _mockStakedTotalValue(200e18, 0);
        _deposit(assets);

        (uint256 cleverDepositAmount, uint256 convexStakeAmount) = afCvx.previewDistribute();

        assertEq(cleverDepositAmount, 40e18);
        assertEq(convexStakeAmount, 10e18);
    }
}
