// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "./Base.t.sol";

contract OwnerTests is Base {

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

    function testSetCleverCvxStrategyShare() public {
        vm.expectRevert(bytes4(keccak256("InvalidShare()")));
        vm.prank(owner);
        AFCVX_PROXY.setCleverCvxStrategyShare(10001);

        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        vm.prank(user);
        AFCVX_PROXY.setCleverCvxStrategyShare(10001);

        vm.prank(owner);
        AFCVX_PROXY.setCleverCvxStrategyShare(10000);

        assertEq(AFCVX_PROXY.cleverStrategyShareBps(), 10000);
    }

    function testSetProtocolFee() public {
        vm.expectRevert(bytes4(keccak256("InvalidFee()")));
        vm.prank(owner);
        AFCVX_PROXY.setProtocolFee(10001);

        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        vm.prank(user);
        AFCVX_PROXY.setProtocolFee(10001);

        vm.prank(owner);
        AFCVX_PROXY.setProtocolFee(10000);

        assertEq(AFCVX_PROXY.protocolFeeBps(), 10000);
    }

    function testSetWithdrawalFee() public {
        vm.expectRevert(bytes4(keccak256("InvalidFee()")));
        vm.prank(owner);
        AFCVX_PROXY.setWithdrawalFee(10001);

        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        vm.prank(user);
        AFCVX_PROXY.setWithdrawalFee(10001);

        vm.prank(owner);
        AFCVX_PROXY.setWithdrawalFee(10000);

        assertEq(AFCVX_PROXY.withdrawalFeeBps(), 10000);
    }

    function testSetWeeklyWithdrawShare() public {
        vm.expectRevert(bytes4(keccak256("InvalidShare()")));
        vm.prank(owner);
        AFCVX_PROXY.setWeeklyWithdrawShare(10001);

        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        vm.prank(user);
        AFCVX_PROXY.setWeeklyWithdrawShare(10001);

        vm.prank(owner);
        AFCVX_PROXY.setWeeklyWithdrawShare(10000);

        assertEq(AFCVX_PROXY.weeklyWithdrawalShareBps(), 10000);
    }

    function testSetProtocolFeeCollector() public {
        vm.expectRevert(bytes4(keccak256("InvalidAddress()")));
        vm.prank(owner);
        AFCVX_PROXY.setProtocolFeeCollector(address(0));

        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        vm.prank(user);
        AFCVX_PROXY.setProtocolFeeCollector(address(0));

        vm.prank(owner);
        AFCVX_PROXY.setProtocolFeeCollector(address(0x1234567890123456789012345678901234567890));

        assertEq(AFCVX_PROXY.protocolFeeCollector(), address(0x1234567890123456789012345678901234567890));
    }

    function testSetOperator() public {
        vm.expectRevert(bytes4(keccak256("InvalidAddress()")));
        vm.prank(owner);
        AFCVX_PROXY.setOperator(address(0));

        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        vm.prank(user);
        AFCVX_PROXY.setOperator(address(0));

        vm.prank(owner);
        AFCVX_PROXY.setOperator(address(0x1234567890123456789012345678901234567890));

        assertEq(AFCVX_PROXY.operator(), address(0x1234567890123456789012345678901234567890));
    }

    function testSetPaused() public {
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        vm.prank(user);
        AFCVX_PROXY.setPaused(true);

        vm.prank(owner);
        AFCVX_PROXY.setPaused(true);

        assertEq(AFCVX_PROXY.paused(), true);
    }

    function testSweep() public {
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        vm.prank(user);
        AFCVX_PROXY.sweep();

        uint256 _sweepAmount = 1 ether;
        uint256 _ownerBalanceBefore = address(AFCVX_PROXY).balance;

        vm.deal({ account: address(AFCVX_PROXY), newBalance: _sweepAmount });

        vm.prank(owner);
        AFCVX_PROXY.sweep();

        assertEq(address(AFCVX_PROXY).balance, 0, "testSweep: E0");
        assertEq(address(owner).balance, _ownerBalanceBefore + _sweepAmount, "testSweep: E1");
    }
}