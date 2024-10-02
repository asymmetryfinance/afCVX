// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "./Base.t.sol";

contract LPTests is Base { // @todo - test rewards

    // ============================================================================================
    // Setup
    // ============================================================================================

    function setUp() public override {
        Base.setUp();

        _upgradeImplementations();
    }

    // ============================================================================================
    // Tests
    // ============================================================================================

    function testSweepCVX(uint256 _amount) public {
        vm.assume(_amount > 0 && _amount < 1000 ether);
        deal({ token: address(CVX), to: address(LPSTRATEGY_PROXY), give: _amount * 10 ** CVX.decimals() });

        vm.expectRevert();
        LPSTRATEGY_PROXY.sweep(_amount, address(CVX));

        uint256 _balanceBefore = CVX.balanceOf(address(AFCVX_PROXY));

        vm.prank(LPSTRATEGY_PROXY.owner());
        LPSTRATEGY_PROXY.sweep(_amount, address(CVX));

        assertEq(CVX.balanceOf(address(AFCVX_PROXY)), _balanceBefore + _amount, "testSweepCVX: E0");
    }

    function testSweepNonCVX(uint256 _amount) public {
        vm.assume(_amount > 0 && _amount < 1000 ether);
        deal({ token: address(CVXCRV), to: address(LPSTRATEGY_PROXY), give: _amount * 10 ** CVXCRV.decimals() });

        vm.expectRevert();
        LPSTRATEGY_PROXY.sweep(_amount, address(CVXCRV));

        uint256 _balanceBefore = CVXCRV.balanceOf(owner);

        vm.prank(LPSTRATEGY_PROXY.owner());
        LPSTRATEGY_PROXY.sweep(_amount, address(CVXCRV));

        assertEq(CVXCRV.balanceOf(LPSTRATEGY_PROXY.owner()), _balanceBefore + _amount, "testSweepNonCVX: E0");
    }
}