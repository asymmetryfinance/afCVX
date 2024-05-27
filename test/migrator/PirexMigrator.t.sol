// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {PirexMigrator, ICVXLocker, IPirexCVX} from "../../src/PirexMigrator.sol";

import "forge-std/Test.sol";
import "forge-std/console.sol";

contract PirexMigratorTests is Test {

    address payable public user;

    uint256[] _emptyArray;

    PirexMigrator public migrator;

    // ============================================================================================
    // Setup
    // ============================================================================================

    function setUp() public {

        vm.selectFork(vm.createFork(vm.envString("ETHEREUM_RPC_URL")));

        // Initialize user
        user = payable(makeAddr("user"));
        vm.deal({ account: user, newBalance: 100 ether });

        // Initialize migrator
        migrator = new PirexMigrator(user);
        vm.label({ account: address(migrator), newLabel: "PirexMigrator" });
    }

    // ============================================================================================
    // Tests
    // ============================================================================================

    function testMigrateUnionCVXWithSwap(uint256 _amount) public {
        vm.assume(_amount > 0.1 ether && _amount < 100 ether);

        _dealUnionCVX(_amount, user);

        assertEq(migrator.UNION_CVX().balanceOf(user), _amount, "testMigrateUnionCVXWithSwap: E0");
        assertEq(migrator.UNION_CVX().balanceOf(address(migrator)), 0, "testMigrateUnionCVXWithSwap: E1");
        assertEq(migrator.ASYMMETRY_CVX().balanceOf(user), 0, "testMigrateUnionCVXWithSwap: E2");
        assertEq(migrator.ASYMMETRY_CVX().balanceOf(address(migrator)), 0, "testMigrateUnionCVXWithSwap: E3");

        vm.startPrank(user);

        migrator.UNION_CVX().approve(address(migrator), _amount);

        vm.expectRevert();
        migrator.migrate(_emptyArray, _amount, 1, 0, user, false, true);

        vm.expectRevert(bytes4(keccak256("ZeroAmount()")));
        migrator.migrate(_emptyArray, 0, 1, 0, user, true, true);

        vm.expectRevert(bytes4(keccak256("ZeroAmount()")));
        migrator.migrate(_emptyArray, _amount, 0, 0, user, true, true);

        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        migrator.migrate(_emptyArray, _amount, 1, 0, address(0), true, true);

        uint256 _afCVXReceived = migrator.migrate(_emptyArray, _amount, 1, 0, user, true, true);

        vm.stopPrank();

        assertEq(migrator.UNION_CVX().balanceOf(user), 0, "testMigrateUnionCVXWithSwap: E4");
        assertEq(migrator.UNION_CVX().balanceOf(address(migrator)), 0, "testMigrateUnionCVXWithSwap: E5");
        assertEq(migrator.ASYMMETRY_CVX().balanceOf(user), _afCVXReceived, "testMigrateUnionCVXWithSwap: E6");
        assertEq(migrator.ASYMMETRY_CVX().balanceOf(address(migrator)), 0, "testMigrateUnionCVXWithSwap: E7");
        assertTrue(_afCVXReceived > 0, "testMigrateUnionCVXWithSwap: E8");
    }

    function testMigratePirexCVXWithSwap(uint256 _amount) public {
        vm.assume(_amount > 0.1 ether && _amount < 100 ether);

        _dealPirexCVX(_amount, user);

        assertEq(migrator.PX_CVX().balanceOf(user), _amount, "testMigrateUnionCVXWithSwap: E0");
        assertEq(migrator.PX_CVX().balanceOf(address(migrator)), 0, "testMigrateUnionCVXWithSwap: E1");
        assertEq(migrator.ASYMMETRY_CVX().balanceOf(user), 0, "testMigrateUnionCVXWithSwap: E2");
        assertEq(migrator.ASYMMETRY_CVX().balanceOf(address(migrator)), 0, "testMigrateUnionCVXWithSwap: E3");

        vm.startPrank(user);

        migrator.PX_CVX().approve(address(migrator), _amount);

        uint256 _afCVXReceived = migrator.migrate(_emptyArray, _amount, 1, 0, user, false, true);

        vm.stopPrank();

        assertEq(migrator.PX_CVX().balanceOf(user), 0, "testMigrateUnionCVXWithSwap: E4");
        assertEq(migrator.PX_CVX().balanceOf(address(migrator)), 0, "testMigrateUnionCVXWithSwap: E5");
        assertEq(migrator.ASYMMETRY_CVX().balanceOf(user), _afCVXReceived, "testMigrateUnionCVXWithSwap: E6");
        assertEq(migrator.ASYMMETRY_CVX().balanceOf(address(migrator)), 0, "testMigrateUnionCVXWithSwap: E7");
        assertTrue(_afCVXReceived > 0, "testMigrateUnionCVXWithSwap: E8");
    }

    function testMigrateNoSwap(uint256 _amount) public {
        vm.assume(_amount > 0.1 ether && _amount < 100 ether);

        _dealPirexCVX(_amount, user);

        (,,,ICVXLocker.LockedBalance[] memory _lockData) = migrator.CVX_LOCKER().lockedBalances(address(migrator.PIREX_CVX()));

        uint256 _lockIndex = 0;
        uint256 _unlockTime = _lockData[0].unlockTime;
        uint256 _upxCVXUserBalanceBefore = migrator.UPX_CVX().balanceOf(user, _unlockTime);
        uint256 _upxCVXMigratorBalanceBefore = migrator.UPX_CVX().balanceOf(address(migrator), _unlockTime);

        vm.startPrank(user);

        migrator.PX_CVX().approve(address(migrator), _amount);

        uint256 _upxCVXCredited = migrator.migrate(_emptyArray, _amount, 0, _lockIndex, user, false, false);

        uint256 _upxCVXUserBalanceAfter = migrator.UPX_CVX().balanceOf(user, _unlockTime);
        uint256 _upxCVXMigratorBalanceAfter = migrator.UPX_CVX().balanceOf(address(migrator), _unlockTime);

        assertEq(_upxCVXCredited, _upxCVXMigratorBalanceAfter, "testMigrateUnionCVXWithSwap: E0");
        assertEq(_upxCVXUserBalanceBefore, 0, "testMigrateUnionCVXWithSwap: E1");
        assertEq(_upxCVXMigratorBalanceBefore, 0, "testMigrateUnionCVXWithSwap: E2");
        assertEq(_upxCVXUserBalanceAfter, 0, "testMigrateUnionCVXWithSwap: E3");
        assertTrue(_upxCVXMigratorBalanceAfter > 0, "testMigrateUnionCVXWithSwap: E4");

        skip(_unlockTime - block.timestamp);

        uint256[] memory _unlockTimes = new uint256[](1);
        _unlockTimes[0] = _unlockTime;

        address[] memory _fors = new address[](1);
        _fors[0] = user;
        _amount = migrator.multiRedeem(_unlockTimes, _fors);

        assertEq(migrator.UPX_CVX().balanceOf(user, _unlockTime), 0, "testMigrateUnionCVXWithSwap: E5");
        assertEq(migrator.ASYMMETRY_CVX().balanceOf(user), _amount, "testMigrateUnionCVXWithSwap: E6");
        assertEq(migrator.UPX_CVX().balanceOf(address(migrator), _unlockTime), 0, "testMigrateUnionCVXWithSwap: E7");
        assertTrue(_amount > 0, "testMigrateUnionCVXWithSwap: E8");

        vm.stopPrank();
    }

    function testMigrateWithUnlockingPirexCVX(uint256 _amount) public {
        vm.assume(_amount > 0.1 ether && _amount < 100 ether);

        _dealPirexCVX(_amount, user);

        (,,,ICVXLocker.LockedBalance[] memory _lockData) = migrator.CVX_LOCKER().lockedBalances(address(migrator.PIREX_CVX()));

        uint256 _lockIndex = 0;
        uint256 _unlockTime = _lockData[0].unlockTime;
        uint256 _upxCVXBalanceBefore = migrator.UPX_CVX().balanceOf(user, _unlockTime);

        vm.startPrank(user);

        migrator.PX_CVX().approve(address(migrator), _amount);

        {
            uint256[] memory _assets = new uint256[](1);
            _assets[0] = _amount;
            uint256[] memory _lockIndexes = new uint256[](1);
            _lockIndexes[0] = _lockIndex;
            migrator.PIREX_CVX().initiateRedemptions(_lockIndexes, IPirexCVX.Futures.Reward, _assets, user);
        }

        uint256 _upxCVXBalanceAfter = migrator.UPX_CVX().balanceOf(user, _unlockTime);

        assertEq(_upxCVXBalanceBefore, 0, "testMigrateUnionCVXWithSwap: E1");
        assertTrue(_upxCVXBalanceAfter > 0, "testMigrateUnionCVXWithSwap: E2");

        skip(_unlockTime - block.timestamp);

        uint256[] memory _unlockTimes = new uint256[](1);
        _unlockTimes[0] = _unlockTime;
        uint256[] memory _amounts = new uint256[](1);
        _amounts[0] = _upxCVXBalanceAfter;

        migrator.UPX_CVX().setApprovalForAll(address(migrator), true);

        _amount = migrator.migrate(_unlockTimes, _amounts, user);

        assertEq(migrator.UPX_CVX().balanceOf(user, _unlockTime), 0, "testMigrateUnionCVXWithSwap: E3");
        assertEq(migrator.ASYMMETRY_CVX().balanceOf(user), _amount, "testMigrateUnionCVXWithSwap: E4");

        vm.stopPrank();
    }

    function testGetRedemptionFee() public view {
        uint256 _amount = 100 ether;
        uint256 _lockIndexSoon = 0;
        uint256 _lockIndexLate = 5;
        uint256 _feeAmountSoon = migrator.getRedemptionFee(_amount, _lockIndexSoon);
        uint256 _feeAmountLate = migrator.getRedemptionFee(_amount, _lockIndexLate);

        assertTrue(_feeAmountSoon > 0, "testGetRedemptionFee: E0");
        assertTrue(_feeAmountLate > 0, "testGetRedemptionFee: E1");
        assertTrue(_feeAmountLate < _feeAmountSoon, "testGetRedemptionFee: E2");
    }

    // ============================================================================================
    // Internal helpers
    // ============================================================================================

    function _dealUnionCVX(uint256 _amount, address _receiver) internal {
        deal({ token: address(migrator.UNION_CVX()), to: _receiver, give: _amount });
    }

    function _dealPirexCVX(uint256 _amount, address _receiver) internal {
        deal({ token: address(migrator.PX_CVX()), to: _receiver, give: _amount });
    }
}