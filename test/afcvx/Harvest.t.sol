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

    function testHarvest() public { // TODO - test withdrawalLimit

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