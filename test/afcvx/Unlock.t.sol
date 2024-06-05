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
            0x4f9ccE86D68Ee24275B9A2EDfC4eF52bd5e5b87c,
            0xc42cEb990DeB305520C4527F2a841506095A55D6,
            0x82a3b3274949C050952f8F826B099525f3A4572F,
            0x76a1F47f8d998D07a15189a07d9aADA180E09aC6,
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

        _deposit(AFCVX_PROXY.totalAssets(), user);
        _requestUnlock(1 ether, user);

        _totalAssetsBefore = AFCVX_PROXY.totalAssets();
        _totalSupplyBefore = AFCVX_PROXY.totalSupply();
        uint256 _cleverStrategyNetAssetsBefore = CLEVERCVXSTRATEGY_PROXY.netAssets();

        uint256 _currentEpoch = block.timestamp / 1 weeks;
        uint256 _nextUnlockEpoch = _getNextUnlockEpoch(0);
        while (_nextUnlockEpoch != 0) {
            _currentEpoch = _processUnlockObligations(_nextUnlockEpoch, _currentEpoch);
            _nextUnlockEpoch = _getNextUnlockEpoch(_nextUnlockEpoch);
        }

        assertEq(CLEVERCVXSTRATEGY_PROXY.unlockObligations(), 0, "testProcessCurrentUnlockObligations: E2");
        assertEq(AFCVX_PROXY.totalAssets(), _totalAssetsBefore, "testProcessCurrentUnlockObligations: E3");
        assertEq(AFCVX_PROXY.totalSupply(), _totalSupplyBefore, "testProcessCurrentUnlockObligations: E4");
        assertEq(CLEVERCVXSTRATEGY_PROXY.netAssets(), _cleverStrategyNetAssetsBefore, "testProcessCurrentUnlockObligations: E5");
        assertEq(CVX.balanceOf(address(CLEVERCVXSTRATEGY_PROXY)), 0, "testProcessCurrentUnlockObligations: E6");
    }

    function testProcessCurrentUnlockObligationsWithFee() public {
        _updateCLeverRepaymentFeePercentage(); // set 1% repayment fee
        testProcessCurrentUnlockObligations();
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
        CLEVERCVXSTRATEGY_PROXY.repay();
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
        assertEq(AFCVX_PROXY.maxRequestUnlock(_user), 1 + _maxUserUnlockBefore - _shares, "_requestUnlock: E3");
        assertEq(_assets, _expectedAssets, "_requestUnlock: E4");
    }
}