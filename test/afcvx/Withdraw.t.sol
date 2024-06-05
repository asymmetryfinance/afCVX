// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "./Base.t.sol";

contract WithdrawTests is Base {

    // ============================================================================================
    // Setup
    // ============================================================================================

    function setUp() public override {
        Base.setUp();
    }

    // ============================================================================================
    // Tests
    // ============================================================================================

    function testRedeem(uint256 _shares) public {
        uint256 _assets = 10 ether;
        _deposit(_assets, user);

        vm.assume(_shares > 0 ether && _shares < AFCVX_PROXY.maxRedeem(user));
        _shares = _shares / 2;

        // Redeem before upgrade

        uint256 _totalSupply = AFCVX_PROXY.totalSupply();
        uint256 _totalAssets = AFCVX_PROXY.totalAssets();
        uint256 _sharesBeforeUpgrade = AFCVX_PROXY.balanceOf(user);

        uint256 _assetsPreviewBeforeUpgrade = AFCVX_PROXY.previewRedeem(_shares);

        vm.prank(user);
        uint256 _assetsBeforeUpgrade = AFCVX_PROXY.redeem(_shares, user, user);

        assertEq(AFCVX_PROXY.balanceOf(user), _sharesBeforeUpgrade - _shares, "testRedeem: E0");
        assertEq(AFCVX_PROXY.totalSupply(), _totalSupply - _shares, "testRedeem: E1");
        assertEq(AFCVX_PROXY.totalAssets(), _totalAssets - _assetsBeforeUpgrade, "testRedeem: E2");
        assertEq(_assetsPreviewBeforeUpgrade, _assetsBeforeUpgrade, "testRedeem: E3");

        _totalSupply = AFCVX_PROXY.totalSupply();
        _totalAssets = AFCVX_PROXY.totalAssets();

        // Redeem after upgrade

        _upgradeImplementations();

        assertEq(_totalSupply, AFCVX_PROXY.totalSupply(), "testRedeem: E4");
        assertEq(_totalAssets, AFCVX_PROXY.totalAssets(), "testRedeem: E5");

        uint256 _sharesAfterUpgrade = AFCVX_PROXY.balanceOf(user);
        uint256 _assetsPreviewAfterUpgrade = AFCVX_PROXY.previewRedeem(_shares);

        vm.prank(user);
        uint256 _assetsAfterUpgrade = AFCVX_PROXY.redeem(_shares, user, user);

        assertEq(AFCVX_PROXY.balanceOf(user), _sharesAfterUpgrade - _shares, "testRedeem: E6");
        assertEq(AFCVX_PROXY.totalSupply(), _totalSupply - _shares, "testRedeem: E7");
        assertEq(AFCVX_PROXY.totalAssets(), _totalAssets - _assetsAfterUpgrade, "testRedeem: E8");
        assertEq(_assetsPreviewAfterUpgrade, _assetsAfterUpgrade, "testRedeem: E9");

        // big difference because of fee calculation
        // notice that before the upgrade, users were paying a lower withdrawal fee on `withdraw` than on `redeem`
        // as `previewWithdraw` and `previewRedeem` were calculating the fee differently (https://github.com/asymmetryfinance/afCVX/blob/d062dc416d7afc99d45424fc8ad4ee045d08c667/src/AfCvx.sol#L234)
        assertApproxEqAbs(_assetsBeforeUpgrade, _assetsAfterUpgrade, 1e15, "testRedeem: E10");

        vm.stopPrank();
    }

    function testWithdraw(uint256 _assets) public {
        _deposit(10 ether, user);

        vm.assume(_assets > 0 ether && _assets < AFCVX_PROXY.maxWithdraw(user));

        _assets = _assets / 2;

        // Withdraw before upgrade

        uint256 _totalSupply = AFCVX_PROXY.totalSupply();
        uint256 _totalAssets = AFCVX_PROXY.totalAssets();
        uint256 _sharesBalanceBeforeUpgrade = AFCVX_PROXY.balanceOf(user);

        uint256 _sharesPreviewBeforeUpgrade = AFCVX_PROXY.previewWithdraw(_assets);

        vm.prank(user);
        uint256 _sharesBeforeUpgrade = AFCVX_PROXY.withdraw(_assets, user, user);

        assertEq(AFCVX_PROXY.balanceOf(user), _sharesBalanceBeforeUpgrade - _sharesBeforeUpgrade, "testWithdraw: E0");
        assertEq(AFCVX_PROXY.totalSupply(), _totalSupply - _sharesBeforeUpgrade, "testWithdraw: E1");
        assertEq(AFCVX_PROXY.totalAssets(), _totalAssets - _assets, "testWithdraw: E2");
        assertEq(_sharesPreviewBeforeUpgrade, _sharesBeforeUpgrade, "testWithdraw: E3");

        _totalSupply = AFCVX_PROXY.totalSupply();
        _totalAssets = AFCVX_PROXY.totalAssets();

        // Withdraw after upgrade

        _upgradeImplementations();

        assertEq(_totalSupply, AFCVX_PROXY.totalSupply(), "testWithdraw: E4");
        assertEq(_totalAssets, AFCVX_PROXY.totalAssets(), "testWithdraw: E5");

        uint256 _sharesBalanceAfterUpgrade = AFCVX_PROXY.balanceOf(user);
        uint256 _sharesPreviewAfterUpgrade = AFCVX_PROXY.previewWithdraw(_assets);

        vm.prank(user);
        uint256 _sharesAfterUpgrade = AFCVX_PROXY.withdraw(_assets, user, user);

        assertEq(AFCVX_PROXY.balanceOf(user), _sharesBalanceAfterUpgrade - _sharesAfterUpgrade, "testWithdraw: E6");
        assertEq(AFCVX_PROXY.totalSupply(), _totalSupply - _sharesAfterUpgrade, "testWithdraw: E7");
        assertEq(AFCVX_PROXY.totalAssets(), _totalAssets - _assets, "testWithdraw: E8");
        assertEq(_sharesPreviewAfterUpgrade, _sharesAfterUpgrade, "testWithdraw: E10");
        assertApproxEqAbs(_sharesBeforeUpgrade, _sharesAfterUpgrade, 1e13, "testWithdraw: E10");

        vm.stopPrank();
    }

    function testMaxRedeemLimit() public {
        _deposit(AFCVX_PROXY.totalAssets(), user);

        assertTrue(AFCVX_PROXY.convertToAssets(AFCVX_PROXY.balanceOf(user)) > AFCVX_PROXY.weeklyWithdrawalLimit(), "testMaxRedeemLimit: E0");
        assertTrue(AFCVX_PROXY.weeklyWithdrawalLimit() > 0, "testMaxRedeemLimit: E1");

        uint256 _userAssetsBefore = CVX.balanceOf(user);
        uint256 _userSharesBefore = AFCVX_PROXY.balanceOf(user);
        uint256 _maxRedeem = AFCVX_PROXY.maxRedeem(user);
        uint256 _expectedAssets = AFCVX_PROXY.previewRedeem(_maxRedeem);

        vm.prank(user);
        uint256 _actualAssets = AFCVX_PROXY.redeem(_maxRedeem, user, user);

        assertEq(AFCVX_PROXY.weeklyWithdrawalLimit(), 1, "testMaxRedeemLimit: E2");
        assertEq(AFCVX_PROXY.maxRedeem(user), 1, "testMaxRedeemLimit: E3");
        assertEq(_expectedAssets, _actualAssets, "testMaxRedeemLimit: E4");
        assertEq(CVX.balanceOf(user), _userAssetsBefore + _expectedAssets, "testMaxRedeemLimit: E5");
        assertEq(AFCVX_PROXY.balanceOf(user), _userSharesBefore - _maxRedeem, "testMaxRedeemLimit: E6");
    }

    function testMaxWithdrawLimit() public {
        _deposit(AFCVX_PROXY.totalAssets(), user);

        assertTrue(AFCVX_PROXY.convertToAssets(AFCVX_PROXY.balanceOf(user)) > AFCVX_PROXY.weeklyWithdrawalLimit(), "testMaxWithdrawLimit: E0");
        assertTrue(AFCVX_PROXY.weeklyWithdrawalLimit() > 0, "testMaxWithdrawLimit: E1");

        uint256 _userAssetsBefore = CVX.balanceOf(user);
        uint256 _userSharesBefore = AFCVX_PROXY.balanceOf(user);
        uint256 _maxWithdraw = AFCVX_PROXY.maxWithdraw(user);
        uint256 _expectedShares = AFCVX_PROXY.previewWithdraw(_maxWithdraw);

        vm.prank(user);
        uint256 _actualShares = AFCVX_PROXY.withdraw(_maxWithdraw, user, user);

        assertEq(AFCVX_PROXY.weeklyWithdrawalLimit(), 0, "testMaxWithdrawLimit: E2");
        assertEq(AFCVX_PROXY.maxWithdraw(user), 0, "testMaxWithdrawLimit: E3");
        assertEq(_expectedShares, _actualShares, "testMaxWithdrawLimit: E4");
        assertEq(CVX.balanceOf(user), _userAssetsBefore + _maxWithdraw, "testMaxWithdrawLimit: E5");
        assertEq(AFCVX_PROXY.balanceOf(user), _userSharesBefore - _expectedShares, "testMaxWithdrawLimit: E6");
    }
}