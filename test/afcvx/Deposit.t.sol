// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "./Base.t.sol";

contract DepositTests is Base {

    // ============================================================================================
    // Setup
    // ============================================================================================

    function setUp() public override {
        Base.setUp();
    }

    // ============================================================================================
    // Tests
    // ============================================================================================

    function testDeposit(uint256 _assets) public {
        vm.assume(_assets > 0 ether && _assets < 100 ether);

        // Harvest before upgrade because totalAssets does not include rewards
        vm.prank(owner);
        AFCVX_PROXY.harvest(0);

        // Deposit before upgrade

        uint256 _totalSupply = AFCVX_PROXY.totalSupply();
        uint256 _totalAssets = AFCVX_PROXY.totalAssets();

        vm.startPrank(user);

        uint256 _sharesPreviewBeforeUpgrade = AFCVX_PROXY.previewDeposit(_assets);

        CVX.approve(address(AFCVX_PROXY), _assets);
        uint256 _sharesBeforeUpgrade = AFCVX_PROXY.deposit(_assets, user);

        assertEq(AFCVX_PROXY.balanceOf(user), _sharesBeforeUpgrade, "testDeposit: E0");
        assertEq(AFCVX_PROXY.totalSupply(), _totalSupply + _sharesBeforeUpgrade, "testDeposit: E1");
        assertEq(AFCVX_PROXY.totalAssets(), _totalAssets + _assets, "testDeposit: E2");
        assertEq(_sharesPreviewBeforeUpgrade, _sharesBeforeUpgrade, "testDeposit: E3");

        vm.stopPrank();

        _totalSupply = AFCVX_PROXY.totalSupply();
        _totalAssets = AFCVX_PROXY.totalAssets();


        // Deposit after upgrade

        _upgradeImplementations();

        assertEq(_totalSupply, AFCVX_PROXY.totalSupply(), "testDeposit: E4");
        assertEq(_totalAssets, AFCVX_PROXY.totalAssets(), "testDeposit: E5");

        vm.startPrank(user);

        uint256 _sharesPreviewAfterUpgrade = AFCVX_PROXY.previewDeposit(_assets);

        CVX.approve(address(AFCVX_PROXY), _assets);
        uint256 _sharesAfterUpgrade = AFCVX_PROXY.deposit(_assets, user);

        assertEq(AFCVX_PROXY.balanceOf(user), _sharesAfterUpgrade + _sharesBeforeUpgrade, "testDeposit: E6");
        assertEq(AFCVX_PROXY.totalSupply(), _totalSupply + _sharesAfterUpgrade, "testDeposit: E7");
        assertEq(AFCVX_PROXY.totalAssets(), _totalAssets + _assets, "testDeposit: E8");
        assertEq(_sharesPreviewAfterUpgrade, _sharesAfterUpgrade, "testDeposit: E9");
        assertEq(_sharesAfterUpgrade, _sharesBeforeUpgrade, "testDeposit: E10");

        vm.stopPrank();
    }

    function testMint(uint256 _shares) public {
        vm.assume(_shares > 0 ether && _shares < 100 ether);

        // Harvest before upgrade because totalAssets does not include rewards
        vm.prank(owner);
        AFCVX_PROXY.harvest(0);

        // Deposit before upgrade

        uint256 _totalSupply = AFCVX_PROXY.totalSupply();
        uint256 _totalAssets = AFCVX_PROXY.totalAssets();

        vm.startPrank(user);

        uint256 _assetsPreviewBeforeUpgrade = AFCVX_PROXY.previewMint(_shares);

        CVX.approve(address(AFCVX_PROXY), _assetsPreviewBeforeUpgrade);
        uint256 _assetsBeforeUpgrade = AFCVX_PROXY.mint(_shares, user);

        assertEq(AFCVX_PROXY.balanceOf(user), _shares, "testMint: E0");
        assertEq(AFCVX_PROXY.totalSupply(), _totalSupply + _shares, "testMint: E1");
        assertEq(AFCVX_PROXY.totalAssets(), _totalAssets + _assetsBeforeUpgrade, "testMint: E2");
        assertEq(_assetsPreviewBeforeUpgrade, _assetsBeforeUpgrade, "testMint: E3");

        vm.stopPrank();

        _totalSupply = AFCVX_PROXY.totalSupply();
        _totalAssets = AFCVX_PROXY.totalAssets();


        // Deposit after upgrade

        _upgradeImplementations();

        assertEq(_totalSupply, AFCVX_PROXY.totalSupply(), "testMint: E4");
        assertEq(_totalAssets, AFCVX_PROXY.totalAssets(), "testMint: E5");

        vm.startPrank(user);

        uint256 _assetsPreviewAfterUpgrade = AFCVX_PROXY.previewMint(_shares);

        CVX.approve(address(AFCVX_PROXY), _assetsPreviewAfterUpgrade);
        uint256 _assetsAfterUpgrade = AFCVX_PROXY.mint(_shares, user);

        assertEq(AFCVX_PROXY.balanceOf(user), _shares * 2, "testMint: E6");
        assertEq(AFCVX_PROXY.totalSupply(), _totalSupply + _shares, "testMint: E7");
        assertEq(AFCVX_PROXY.totalAssets(), _totalAssets + _assetsAfterUpgrade, "testMint: E8");
        assertEq(_assetsPreviewAfterUpgrade, _assetsAfterUpgrade, "testMint: E9");
        assertEq(_assetsAfterUpgrade, _assetsBeforeUpgrade, "testMint: E10");

        vm.stopPrank();
    }
}