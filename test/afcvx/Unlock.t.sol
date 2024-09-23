// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "./Base.t.sol";

contract UnlockTests is Base {

    address[] public unlockers;

    // ============================================================================================
    // Setup
    // ============================================================================================

    function setUp() public override {
        Base.setUp();

        // from utils/fetch_events.py
        unlockers = [
            0x717c4624365BEB1AEA1b1486d87372d488794A21,
            0x4F17c5a9c090E8C343a1965bf0CA7633DB2Cd72b,
            0xC1415496475d70Cfe84D5360864F8A89e7b6CF28,
            0xB8595D024AFa36E0205AF627E3b47bd5CA0cf67a,
            0x8625AfdbF3744D433D850c681Ba881d028253c8A,
            user
        ];
    }

    // ============================================================================================
    // Tests
    // ============================================================================================

    function testProcessCurrentUnlockObligations() public {
        uint256 _totalAssetsBefore = AFCVX_PROXY.totalAssets();
        uint256 _totalSupplyBefore = AFCVX_PROXY.totalSupply();

        _upgradeImplementations();

        assertEq(_totalAssetsBefore, AFCVX_PROXY.totalAssets(), "testProcessCurrentUnlockObligations: E0");
        assertEq(_totalSupplyBefore, AFCVX_PROXY.totalSupply(), "testProcessCurrentUnlockObligations: E1");

        _deposit(10 ether, user);
        _requestUnlock(1 ether, user);

        _totalAssetsBefore = AFCVX_PROXY.totalAssets();
        _totalSupplyBefore = AFCVX_PROXY.totalSupply();
        uint256 _cleverStrategyNetAssetsBefore = CLEVERCVXSTRATEGY_PROXY.netAssets(AFCVX_PROXY.protocolFeeBps());

        uint256 _currentEpoch = block.timestamp / 1 weeks;
        uint256 _nextUnlockEpoch = _getNextUnlockEpoch(0);
        while (_nextUnlockEpoch != 0) {
            _currentEpoch = _processUnlockObligations(_nextUnlockEpoch, _currentEpoch);
            _nextUnlockEpoch = _getNextUnlockEpoch(_nextUnlockEpoch);
        }

        assertEq(CLEVERCVXSTRATEGY_PROXY.unlockObligations(), 0, "testProcessCurrentUnlockObligations: E2");
        assertApproxEqAbs(AFCVX_PROXY.totalAssets(), _totalAssetsBefore, 1, "testProcessCurrentUnlockObligations: E3");
        assertEq(AFCVX_PROXY.totalSupply(), _totalSupplyBefore, "testProcessCurrentUnlockObligations: E4");
        assertApproxEqAbs(CLEVERCVXSTRATEGY_PROXY.netAssets(AFCVX_PROXY.protocolFeeBps()), _cleverStrategyNetAssetsBefore, 1, "testProcessCurrentUnlockObligations: E5");
        assertGe(CVX.balanceOf(address(CLEVERCVXSTRATEGY_PROXY)), 0, "testProcessCurrentUnlockObligations: E6"); // there are more unlockers
    }

    function testProcessCurrentUnlockObligationsWithFee() public {
        _updateCLeverRepaymentFeePercentage(); // set 1% repayment fee
        testProcessCurrentUnlockObligations();
    }

    function testMaxUnlock() public {
        _updateCLeverRepaymentFeePercentage(); // set 1% repayment fee
        _upgradeImplementations();

        _deposit(AFCVX_PROXY.totalAssets(), user);
        assertTrue(AFCVX_PROXY.convertToAssets(AFCVX_PROXY.balanceOf(user)) > CLEVERCVXSTRATEGY_PROXY.maxTotalUnlock(), "testMaxUnlock: E0");

        uint256 _maxShares = AFCVX_PROXY.maxRequestUnlock(user);
        uint256 _expectedAssets = AFCVX_PROXY.previewRequestUnlock(_maxShares);
        uint256 _unlockObigationsBefore = CLEVERCVXSTRATEGY_PROXY.unlockObligations();

        vm.prank(user);
        (, uint256 _assets) = AFCVX_PROXY.requestUnlock(_maxShares, user, user);

        assertEq(_assets, _expectedAssets, "testMaxUnlock: E1");
        assertApproxEqAbs(CLEVERCVXSTRATEGY_PROXY.maxTotalUnlock(), 0, 2, "testMaxUnlock: E2");
        assertEq(CLEVERCVXSTRATEGY_PROXY.unlockObligations(), _unlockObigationsBefore + _assets, "testMaxUnlock: E3");
        assertApproxEqAbs(AFCVX_PROXY.maxRequestUnlock(user), 0, 1, "testMaxUnlock: E4");
    }

    // ============================================================================================
    // Internal helpers
    // ============================================================================================

    function _getNextUnlockEpoch(uint256 _lastEpoch) internal view returns (uint256) {
        for (uint256 i = 0; i < unlockers.length; i++) {
            address _user = unlockers[i];
            CleverCvxStrategy.UnlockRequest[] memory _unlockRequests = CLEVERCVXSTRATEGY_PROXY.getRequestedUnlocks(_user);
            if (_unlockRequests.length > 0) {
                for (uint256 j = 0; j < _unlockRequests.length; j++) {
                    if (_unlockRequests[j].unlockEpoch > _lastEpoch) {
                        return _unlockRequests[j].unlockEpoch;
                    }
                }
            }
        }
        return 0;
    }

    function _processUnlockObligations(uint256 _nextUnlockEpoch, uint256 _currentEpoch) internal returns (uint256) {
        vm.startPrank(owner);
        CLEVERCVXSTRATEGY_PROXY.repay(0 ,0);
        vm.roll(block.number + 1);
        CLEVERCVXSTRATEGY_PROXY.unlock();
        vm.stopPrank();

        vm.roll(block.number + 1);
        skip((_nextUnlockEpoch - _currentEpoch) * 1 weeks);
        _currentEpoch = block.timestamp / 1 weeks;

        for (uint256 i = 0; i < unlockers.length; i++) {
            address _userRequestedUnlock = unlockers[i];
            vm.prank(_userRequestedUnlock);
            AFCVX_PROXY.withdrawUnlocked(_userRequestedUnlock);
        }

        return _currentEpoch;
    }

    function _updateCLeverRepaymentFeePercentage() internal {
        vm.prank(Ownable(address(CLEVER_CVX_LOCKER)).owner());
        CLEVER_CVX_LOCKER.updateRepayFeePercentage(1e7); // 1%
    }

    function _requestUnlock(uint256 _shares, address _user) internal {
        uint256 _unlockObligationsBefore = CLEVERCVXSTRATEGY_PROXY.unlockObligations();
        uint256 _maxUserUnlockBefore = AFCVX_PROXY.maxRequestUnlock(_user);
        uint256 _maxTotalUnlockBefore = CLEVERCVXSTRATEGY_PROXY.maxTotalUnlock();
        uint256 _expectedAssets = AFCVX_PROXY.previewRequestUnlock(_shares);

        vm.startPrank(_user);
        (, uint256 _assets) = AFCVX_PROXY.requestUnlock(_shares, _user, _user);
        vm.stopPrank();

        assertEq(CLEVERCVXSTRATEGY_PROXY.maxTotalUnlock(), _maxTotalUnlockBefore - _assets, "_requestUnlock: E1");
        assertEq(CLEVERCVXSTRATEGY_PROXY.unlockObligations(), _unlockObligationsBefore + _assets, "_requestUnlock: E2");
        assertApproxEqAbs(AFCVX_PROXY.maxRequestUnlock(_user), _maxUserUnlockBefore - _shares, 1, "_requestUnlock: E3");
        assertEq(_assets, _expectedAssets, "_requestUnlock: E4");
    }
}