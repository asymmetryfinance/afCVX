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
        skip(5 days);

        assertEq(_totalSupply, AFCVX_PROXY.totalSupply(), "testHarvest: E3");
        assertEq(_totalAssets, AFCVX_PROXY.totalAssets(), "testHarvest: E4");

        vm.prank(owner);
        _rewards = AFCVX_PROXY.harvest(0);

        assertTrue(_rewards > 0, "testHarvest: E5");
        assertTrue(AFCVX_PROXY.totalAssets() > _totalAssets, "testHarvest: E6");
        assertEq(AFCVX_PROXY.totalSupply(), _totalSupply, "testHarvest: E7");
        assertEq(AFCVX_PROXY.weeklyWithdrawalLimit(), ((_totalAssets + _rewards) * AFCVX_PROXY.weeklyWithdrawalShareBps() / 10_000), "testHarvest: E8");
    }

    function testDistribute() public {
        testHarvest();

        assertTrue(CVX.balanceOf(address(AFCVX_PROXY)) > 0, "testDistribute: E0");

        uint256 _totalAssetsBefore = AFCVX_PROXY.totalAssets();
        (uint256 _depositedBefore, , , uint256 _borrowedBefore, ) = CLEVER_CVX_LOCKER.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        uint256 _borrowingCapacityBefore = 1e18 - (_borrowedBefore * 1e18 / _depositedBefore);
        assertApproxEqAbs(_borrowingCapacityBefore, 50e16, 1, "testDistribute: E1");

        vm.prank(owner);
        AFCVX_PROXY.distribute(false, 0);

        assertApproxEqAbs(CVX.balanceOf(address(AFCVX_PROXY)), 0, 1, "testDistribute: E2");
        assertEq(CLEVERCVXSTRATEGY_PROXY.netAssets(), AFCVX_PROXY.totalAssets() * 80 / 100, "testDistribute: E3");
        assertEq(CVX_REWARDS_POOL.balanceOf(address(AFCVX_PROXY)), AFCVX_PROXY.totalAssets() * 20 / 100, "testDistribute: E4");
        assertEq(AFCVX_PROXY.totalAssets(), _totalAssetsBefore, "testDistribute: E5");

        (uint256 _depositedAfter, , , uint256 _borrowedAfter, ) = CLEVER_CVX_LOCKER.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        assertTrue(_borrowingCapacityBefore < 1e18 - (_borrowedAfter * 1e18 / _depositedAfter), "testDistribute: E6");
    }

    function testBorrow() public {
        testDistribute();

        uint256 _totalAssetsBefore = AFCVX_PROXY.totalAssets();
        uint256 _cleverStrategyAssetsBefore = CLEVERCVXSTRATEGY_PROXY.netAssets();

        (uint256 _depositedBefore, , , uint256 _borrowedBefore, ) = CLEVER_CVX_LOCKER.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        uint256 _borrowingCapacityBefore = 1e2 - (_borrowedBefore * 1e2 / _depositedBefore);
        assertApproxEqAbs(_borrowingCapacityBefore, 50, 1, "testDistribute: E1");

        vm.roll(block.number + 1);

        vm.prank(owner);
        CLEVERCVXSTRATEGY_PROXY.borrow();

        assertEq(CLEVERCVXSTRATEGY_PROXY.netAssets(), AFCVX_PROXY.totalAssets() * 80 / 100, "testBorrow: E0");
        assertEq(CVX_REWARDS_POOL.balanceOf(address(AFCVX_PROXY)), AFCVX_PROXY.totalAssets() * 20 / 100, "testBorrow: E1");
        assertEq(AFCVX_PROXY.totalAssets(), _totalAssetsBefore, "testBorrow: E2");
        assertEq(CLEVERCVXSTRATEGY_PROXY.netAssets(), _cleverStrategyAssetsBefore, "testBorrow: E3");

        (uint256 _depositedAfter, , , uint256 _borrowedAfter, ) = CLEVER_CVX_LOCKER.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        assertTrue(_borrowingCapacityBefore < 1e18 - (_borrowedAfter * 1e18 / _depositedAfter), "testBorrow: E4");
    }

    function testDistributeSwap() public {
        testHarvest();

        assertTrue(CVX.balanceOf(address(AFCVX_PROXY)) > 0, "testDistributeSwap: E0");

        (uint256 _depositedInFurnaceBefore, uint256 _rewardsFurnaceBefore) = FURNACE.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        uint256 _totalAssetsBefore = AFCVX_PROXY.totalAssets();
        (uint256 _depositedBefore, , , uint256 _borrowedBefore, ) = CLEVER_CVX_LOCKER.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        uint256 _borrowingCapacityBefore = 1e18 - (_borrowedBefore * 1e18 / _depositedBefore);
        assertApproxEqAbs(_borrowingCapacityBefore, 50e16, 1, "testDistributeSwap: E1");

        vm.prank(owner);
        AFCVX_PROXY.distribute(true, 0);

        assertApproxEqAbs(CVX.balanceOf(address(AFCVX_PROXY)), 0, 1, "testDistributeSwap: E2");
        assertTrue(CLEVERCVXSTRATEGY_PROXY.netAssets() > AFCVX_PROXY.totalAssets() * 80 / 100, "testDistributeSwap: E3");
        assertTrue(CVX_REWARDS_POOL.balanceOf(address(AFCVX_PROXY)) < AFCVX_PROXY.totalAssets() * 20 / 100, "testDistributeSwap: E4");
        assertTrue(AFCVX_PROXY.totalAssets() > _totalAssetsBefore, "testDistributeSwap: E5"); // dev: getting more clevcvx than cvx we had before

        (uint256 _depositedAfter, , , uint256 _borrowedAfter, ) = CLEVER_CVX_LOCKER.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        assertEq(_borrowingCapacityBefore, 1e18 - (_borrowedAfter * 1e18 / _depositedAfter), "testDistributeSwap: E6"); // dev: no borrowing capacity
        assertEq(_depositedBefore, _depositedAfter, "testDistributeSwap: E7");
        assertEq(_borrowedBefore, _borrowedAfter, "testDistributeSwap: E8");

        (uint256 _depositedInFurnaceAfter, uint256 _rewardsFurnaceAfter) = FURNACE.getUserInfo(address(CLEVERCVXSTRATEGY_PROXY));
        assertTrue(_depositedInFurnaceBefore + _rewardsFurnaceBefore < _depositedInFurnaceAfter + _rewardsFurnaceAfter, "testDistributeSwap: E9");
    }

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
}