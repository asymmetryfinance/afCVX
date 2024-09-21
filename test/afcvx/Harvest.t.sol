// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "./Base.t.sol";

contract HarvestTests is Base {

    // ============================================================================================
    // Setup
    // ============================================================================================

    function setUp() public override {
        Base.setUp();

        // Make sure there's pending rewards in Convex
        _simulateConvexRewards();

        // Make sure there's pending rewards in Clever (Furnace)
        _simulateFurnaceRewards();
    }

    // ============================================================================================
    // Tests
    // ============================================================================================

    function testHarvest() public {

        // Harvest before upgrade

        uint256 _totalSupply = AFCVX_PROXY.totalSupply();
        uint256 _totalAssets = AFCVX_PROXY.totalAssets();

        vm.prank(owner);
        uint256 _rewards = AFCVX_PROXY.harvest(0);

        assertTrue(_rewards > 0, "testHarvest: E0");
        assertTrue(AFCVX_PROXY.totalAssets() > _totalAssets, "testHarvest: E1");
        assertEq(AFCVX_PROXY.totalSupply(), _totalSupply, "testHarvest: E2");

        // Harvest after upgrade

        _totalSupply = AFCVX_PROXY.totalSupply();
        _totalAssets = AFCVX_PROXY.totalAssets();

        _upgradeImplementations();

        // Simulate rewards
        _simulateConvexRewards();
        _simulateFurnaceRewards();
        skip(5 days + AFCVX_PROXY.withdrawalLimitNextUpdate());

        assertEq(_totalSupply, AFCVX_PROXY.totalSupply(), "testHarvest: E3");
        assertEq(_totalAssets, AFCVX_PROXY.totalAssets(), "testHarvest: E4");

        vm.prank(owner);
        _rewards = AFCVX_PROXY.harvest(0);

        assertTrue(_rewards > 0, "testHarvest: E5");
        assertEq(AFCVX_PROXY.totalAssets(), _totalAssets + _rewards, "testHarvest: E6");
        assertEq(AFCVX_PROXY.totalSupply(), _totalSupply, "testHarvest: E7");
        assertEq(AFCVX_PROXY.weeklyWithdrawalLimit(), ((_totalAssets + _rewards) * AFCVX_PROXY.weeklyWithdrawalShareBps() / 10_000), "testHarvest: E8");
        assertEq(AFCVX_PROXY.withdrawalLimitNextUpdate(), block.timestamp + 7 days, "testHarvest: E9");
    }

    function testDistribute() public {
        testHarvest();

        assertTrue(CVX.balanceOf(address(AFCVX_PROXY)) > 0, "testDistribute: E0");

        uint256 _totalAssetsBefore = AFCVX_PROXY.totalAssets();
        (uint256 _depositedBefore, , , uint256 _borrowedBefore, ) = CLEVER_CVX_LOCKER.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        uint256 _borrowingCapacityBefore = 1e18 - (_borrowedBefore * 1e18 / _depositedBefore);
        assertApproxEqAbs(_borrowingCapacityBefore, 50e16, 5, "testDistribute: E1");

        vm.prank(owner);
        AFCVX_PROXY.distribute(type(uint256).max, 0, 0, 0);

        assertApproxEqAbs(CVX.balanceOf(address(AFCVX_PROXY)), 0, 1, "testDistribute: E2");
        // assertEq(CLEVERCVXSTRATEGY_PROXY.netAssets(AFCVX_PROXY.protocolFeeBps()), AFCVX_PROXY.totalAssets() * 80 / 100, "testDistribute: E3");
        // assertApproxEqAbs(CVX_REWARDS_POOL.balanceOf(address(AFCVX_PROXY)), AFCVX_PROXY.totalAssets() * 20 / 100, 1e4, "testDistribute: E4");
        assertEq(AFCVX_PROXY.totalAssets(), _totalAssetsBefore, "testDistribute: E5");

        (uint256 _depositedAfter, , , uint256 _borrowedAfter, ) = CLEVER_CVX_LOCKER.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        assertTrue(_borrowingCapacityBefore < 1e18 - (_borrowedAfter * 1e18 / _depositedAfter), "testDistribute: E6");
    }

    function testBorrow() public {
        testDistribute();

        uint256 _totalAssetsBefore = AFCVX_PROXY.totalAssets();
        uint256 _cleverStrategyAssetsBefore = CLEVERCVXSTRATEGY_PROXY.netAssets(AFCVX_PROXY.protocolFeeBps());

        (uint256 _depositedBefore, , , uint256 _borrowedBefore, ) = CLEVER_CVX_LOCKER.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        uint256 _borrowingCapacityBefore = 1e2 - (_borrowedBefore * 1e2 / _depositedBefore);
        assertApproxEqAbs(_borrowingCapacityBefore, 50, 5, "testDistribute: E1");

        vm.roll(block.number + 1);

        vm.prank(owner);
        CLEVERCVXSTRATEGY_PROXY.borrow();

        // assertEq(CLEVERCVXSTRATEGY_PROXY.netAssets(AFCVX_PROXY.protocolFeeBps()), AFCVX_PROXY.totalAssets() * 80 / 100, "testBorrow: E0");
        // assertApproxEqAbs(CVX_REWARDS_POOL.balanceOf(address(AFCVX_PROXY)), AFCVX_PROXY.totalAssets() * 20 / 100, 1e4, "testBorrow: E1");
        assertEq(AFCVX_PROXY.totalAssets(), _totalAssetsBefore, "testBorrow: E2");
        assertEq(CLEVERCVXSTRATEGY_PROXY.netAssets(AFCVX_PROXY.protocolFeeBps()), _cleverStrategyAssetsBefore, "testBorrow: E3");

        (uint256 _depositedAfter, , , uint256 _borrowedAfter, ) = CLEVER_CVX_LOCKER.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        assertTrue(_borrowingCapacityBefore < 1e18 - (_borrowedAfter * 1e18 / _depositedAfter), "testBorrow: E4");
    }

    function testDistributeSwap(uint256 _maxCleverDeposit, uint256 _swapPercentage) public {
        vm.assume(_swapPercentage > 0 && _swapPercentage < PRECISION);

        testHarvest();

        uint256 _cvxBalanceBefore = CVX.balanceOf(address(AFCVX_PROXY));
        assertTrue(_cvxBalanceBefore > 0, "testDistributeSwap: E0");

        (uint256 _depositedInFurnaceBefore, uint256 _rewardsFurnaceBefore) = FURNACE.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        uint256 _totalAssetsBefore = AFCVX_PROXY.totalAssets();
        (uint256 _depositedBefore, , , uint256 _borrowedBefore, ) = CLEVER_CVX_LOCKER.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        uint256 _borrowingCapacityBefore = 1e18 - (_borrowedBefore * 1e18 / _depositedBefore);
        assertApproxEqAbs(_borrowingCapacityBefore, 50e16, 1, "testDistributeSwap: E1");

        uint256 _expectedSwapAmount;
        uint256 _expectedDepositAmount;
        uint256 _convexExpectedDeposit;
        {
            uint256 _cleverExpectedDeposit;
            (_cleverExpectedDeposit, _convexExpectedDeposit) = _calculateDistribute();
            _cleverExpectedDeposit = _cleverExpectedDeposit > _maxCleverDeposit ? _maxCleverDeposit : _cleverExpectedDeposit;
            _expectedSwapAmount = _cleverExpectedDeposit * _swapPercentage / PRECISION;
            _expectedDepositAmount = _cleverExpectedDeposit - _expectedSwapAmount;
        }

        uint256 _assetsInConvexBefore = CVX_REWARDS_POOL.balanceOf(address(AFCVX_PROXY));

        vm.prank(owner);
        AFCVX_PROXY.distribute(_maxCleverDeposit, _swapPercentage, 0, 0);

        assertApproxEqAbs(CVX.balanceOf(address(AFCVX_PROXY)), _cvxBalanceBefore - _convexExpectedDeposit - _expectedDepositAmount - _expectedSwapAmount, 1, "testDistributeSwap: E2");

        assertGe(1 + AFCVX_PROXY.totalAssets() * 20 / 100, CVX_REWARDS_POOL.balanceOf(address(AFCVX_PROXY)), "testDistributeSwap: E4"); // dev: GE because of getting more clevcvx than cvx we had before
        assertGe(AFCVX_PROXY.totalAssets(), _totalAssetsBefore, "testDistributeSwap: E5"); // dev: getting more clevcvx than cvx we had before

        {
            (uint256 _depositedAfter, , , uint256 _borrowedAfter, ) = CLEVER_CVX_LOCKER.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
            assertLe(_borrowingCapacityBefore, 1e18 - (_borrowedAfter * 1e18 / _depositedAfter), "testDistributeSwap: E6");
            assertEq(_depositedAfter - _depositedBefore, _expectedDepositAmount, "testDistributeSwap: E7");
            assertEq(_borrowedBefore, _borrowedAfter, "testDistributeSwap: E8");
        }

        {
            (uint256 _depositedInFurnaceAfter, uint256 _rewardsFurnaceAfter) = FURNACE.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
            assertTrue((_depositedInFurnaceAfter + _rewardsFurnaceAfter) - (_depositedInFurnaceBefore + _rewardsFurnaceBefore) >= _expectedSwapAmount, "testDistributeSwap: E9");
        }

        assertEq(CVX_REWARDS_POOL.balanceOf(address(AFCVX_PROXY)), _assetsInConvexBefore + _convexExpectedDeposit, "testDistributeSwap: E10");

        if (CVX.balanceOf(address(AFCVX_PROXY)) > 0) _testTwap();
    }

    function _testTwap() public {
        (uint256 _cleverExpectedDeposit, uint256 _convexExpectedDeposit) = _calculateDistribute();
        assertGe(_convexExpectedDeposit, 0, "_testTwap: E0");
        assertGt(_cleverExpectedDeposit, 0, "_testTwap: E1");

        uint256 _totalAssetsBefore = AFCVX_PROXY.totalAssets();
        (uint256 _depositedInFurnaceBefore, uint256 _rewardsFurnaceBefore) = FURNACE.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));

        vm.prank(owner);
        AFCVX_PROXY.distribute(type(uint256).max, PRECISION, 0, 0);

        assertEq(CVX.balanceOf(address(AFCVX_PROXY)), 0, "_testTwap: E2");
        assertGt(AFCVX_PROXY.totalAssets(), _totalAssetsBefore, "_testTwap: E3"); // dev: gt because of swap

        (uint256 _depositedInFurnaceAfter, uint256 _rewardsFurnaceAfter) = FURNACE.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        assertGe(_depositedInFurnaceAfter + _rewardsFurnaceAfter - _cleverExpectedDeposit, _depositedInFurnaceBefore + _rewardsFurnaceBefore, "_testTwap: E4");
    }

    function testDistributeLP() public {
        testHarvest();

        assertTrue(CVX.balanceOf(address(AFCVX_PROXY)) > 0, "testDistributeLP: E0");

        uint256 _lpStrategyCvxBalanceBefore = CVX.balanceOf(address(LPSTRATEGY_PROXY));
        uint256 _totalAssetsBefore = AFCVX_PROXY.totalAssets();
        (uint256 _depositedInFurnaceBefore,) = FURNACE.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        (uint256 _depositedBefore, , , uint256 _borrowedBefore, ) = CLEVER_CVX_LOCKER.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        uint256 _borrowingCapacityBefore = 1e18 - (_borrowedBefore * 1e18 / _depositedBefore);
        assertApproxEqAbs(_borrowingCapacityBefore, 50e16, 5, "testDistributeLP: E1");

        vm.prank(owner);
        AFCVX_PROXY.distribute(type(uint256).max, 0, PRECISION, 0); // LP all

        assertApproxEqAbs(CVX.balanceOf(address(AFCVX_PROXY)), 0, 1, "testDistributeLP: E2");
        assertEq(AFCVX_PROXY.totalAssets(), _totalAssetsBefore, "testDistributeLP: E3");

        (uint256 _depositedInFurnaceAfter,) = FURNACE.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        (uint256 _depositedAfter, , , uint256 _borrowedAfter, ) = CLEVER_CVX_LOCKER.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        assertEq(_borrowingCapacityBefore, 1e18 - (_borrowedAfter * 1e18 / _depositedAfter), "testDistribute: E4");
        assertEq(_depositedBefore, _depositedAfter, "testDistribute: E5");
        assertEq(_depositedInFurnaceBefore, _depositedInFurnaceAfter, "testDistribute: E6");
        assertLt(_lpStrategyCvxBalanceBefore, CVX.balanceOf(address(LPSTRATEGY_PROXY)), "testDistribute: E7");
    }

    function testDistributeFuzzOptions(uint256 _maxCleverDeposit, uint256 _swapPercentage, uint256 _lpPercentage) public {
        vm.assume(_swapPercentage < PRECISION && _lpPercentage < PRECISION);

        testHarvest();

        uint256 _cvxBalanceBefore = CVX.balanceOf(address(AFCVX_PROXY));
        assertTrue(_cvxBalanceBefore > 0, "testDistributeFuzzOptions: E0");

        uint256 _lpStrategyCvxBalanceBefore = CVX.balanceOf(address(LPSTRATEGY_PROXY));
        uint256 _totalAssetsBefore = AFCVX_PROXY.totalAssets();
        uint256  _expectedLPAmount;
        uint256 _expectedSwapAmount;
        uint256 _expectedDepositAmount;
        uint256 _convexExpectedDeposit;
        {
            uint256 _cleverExpectedDeposit;
            (_cleverExpectedDeposit, _convexExpectedDeposit) = _calculateDistribute();
            _cleverExpectedDeposit = _cleverExpectedDeposit > _maxCleverDeposit ? _maxCleverDeposit : _cleverExpectedDeposit;
            if (_lpPercentage > 0) _expectedLPAmount = _cleverExpectedDeposit * _lpPercentage / PRECISION;
            _cleverExpectedDeposit -= _expectedLPAmount;
            if (_swapPercentage > 0) _expectedSwapAmount = _cleverExpectedDeposit * _swapPercentage / PRECISION;
            _expectedDepositAmount = _cleverExpectedDeposit - _expectedSwapAmount;
        }

        uint256 _assetsInConvexBefore = CVX_REWARDS_POOL.balanceOf(address(AFCVX_PROXY));

        vm.prank(owner);
        AFCVX_PROXY.distribute(_maxCleverDeposit, _swapPercentage, _lpPercentage, 0);

        assertApproxEqAbs(CVX.balanceOf(address(AFCVX_PROXY)), _cvxBalanceBefore - _convexExpectedDeposit - _expectedLPAmount - _expectedDepositAmount - _expectedSwapAmount, 1, "testDistributeFuzzOptions: E1");

        assertGe(AFCVX_PROXY.totalAssets(), _totalAssetsBefore, "testDistributeFuzzOptions: E2"); // dev: getting more clevcvx than cvx we had before

        assertEq(CVX_REWARDS_POOL.balanceOf(address(AFCVX_PROXY)), _assetsInConvexBefore + _convexExpectedDeposit, "testDistributeFuzzOptions: E3");
        assertEq(CVX.balanceOf(address(LPSTRATEGY_PROXY)), _lpStrategyCvxBalanceBefore + _expectedLPAmount, "testDistributeFuzzOptions: E4");
    }

    function testSwapFurnaceToLP(uint256 _cvxAmount, uint256 _clevcvxAmount) public {
        testDistributeLP();

        uint256 _lpStrategyCvxBalanceBefore = CVX.balanceOf(address(LPSTRATEGY_PROXY));
        assertGt(_lpStrategyCvxBalanceBefore, 0, "swapFurnaceToLP: E0");

        (uint256 _depositedInFurnaceBefore,) = FURNACE.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        assertGt(_depositedInFurnaceBefore, 0, "swapFurnaceToLP: E1");
        console.log("depositedInFurnaceBefore", _depositedInFurnaceBefore);

        vm.assume(_cvxAmount <= _lpStrategyCvxBalanceBefore && _clevcvxAmount <= _depositedInFurnaceBefore);

        uint256 _totalAssetsBefore = AFCVX_PROXY.totalAssets();

        vm.prank(owner);
        uint256 _lpAmountOut = CLEVERCVXSTRATEGY_PROXY.swapFurnaceToLP(_cvxAmount, _clevcvxAmount, 0);

        assertEq(CVX.balanceOf(address(LPSTRATEGY_PROXY)), _lpStrategyCvxBalanceBefore - _cvxAmount, "swapFurnaceToLP: E2");
        (uint256 _depositedInFurnaceAfter,) = FURNACE.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        assertEq(_depositedInFurnaceAfter, _depositedInFurnaceBefore - _clevcvxAmount, "swapFurnaceToLP: E3");
        assertEq(IERC20(address(LPSTRATEGY_PROXY.LP())).balanceOf(address(LPSTRATEGY_PROXY)), _lpAmountOut, "swapFurnaceToLP: E4");
        assertEq(AFCVX_PROXY.totalAssets(), _totalAssetsBefore, "swapFurnaceToLP: E5");
    }

    // function swapFurnaceToLPInvalidCaller

    // function swapLPToFurnace(

    // ============================================================================================
    // Internal helpers
    // ============================================================================================

    function _simulateConvexRewards() internal {
        deal({ token: address(CVXCRV), to: 0xCF50b810E57Ac33B91dCF525C6ddd9881B139332, give: 10_000 * 10 ** CVXCRV.decimals() });
    }

    function _simulateFurnaceRewards() internal {
        uint256 _rewards = 10_000_000 * 10 ** CVX.decimals();
        address _furnaceOwner = Ownable(address(FURNACE)).owner();
        deal({ token: address(CVX), to: _furnaceOwner, give: _rewards });

        vm.startPrank(_furnaceOwner);
        CVX.approve(address(FURNACE), _rewards);
        FURNACE.distribute(_furnaceOwner, _rewards);
        vm.stopPrank();
    }

    function _calculateDistribute() internal view returns (uint256 _cleverDeposit, uint256 _convexDeposit) {
        uint256 _totalDeposit = CVX.balanceOf(address(AFCVX_PROXY));
        if (_totalDeposit == 0) return (0, 0);

        uint256 _assetsInConvex = CVX_REWARDS_POOL.balanceOf(address(AFCVX_PROXY));
        uint256 _assetsInCLever = CLEVERCVXSTRATEGY_PROXY.netAssets(AFCVX_PROXY.protocolFeeBps());

        uint256 _totalAssets = _totalDeposit + _assetsInConvex + _assetsInCLever;
        uint256 _cleverStrategyShareBps = AFCVX_PROXY.cleverStrategyShareBps();
        uint256 _targetAssetsInCLever = _totalAssets * _cleverStrategyShareBps / PRECISION;
        uint256 _targetAssetsInConvex = _totalAssets - _targetAssetsInCLever;

        uint256 _requiredCLeverDeposit = _targetAssetsInCLever > _assetsInCLever ? _targetAssetsInCLever - _assetsInCLever : 0;
        uint256 _requiredConvexDeposit = _targetAssetsInConvex > _assetsInConvex ? _targetAssetsInConvex - _assetsInConvex : 0;

        uint256 _totalRequiredDeposit = _requiredCLeverDeposit + _requiredConvexDeposit;

        if (_totalRequiredDeposit <= _totalDeposit) {
            _cleverDeposit = _requiredCLeverDeposit;
            _convexDeposit = _requiredConvexDeposit;
            
            // Adjust any remaining amount to ensure all assets are deposited
            uint256 _remainingDeposit = _totalDeposit - _totalRequiredDeposit;
            if (_remainingDeposit > 0) {
                uint256 _cleverShare = _remainingDeposit * _cleverStrategyShareBps / PRECISION;
                _cleverDeposit += _cleverShare;
                _convexDeposit += _remainingDeposit - _cleverShare;
            }
        } else {
            // Proportionally adjust deposits to fit the _totalDeposit
            _cleverDeposit = (_totalDeposit * _requiredCLeverDeposit) / _totalRequiredDeposit;
            _convexDeposit = _totalDeposit - _cleverDeposit;
        }
    }
}