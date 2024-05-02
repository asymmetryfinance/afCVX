// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { CVX } from "src/interfaces/convex/Constants.sol";
import { BaseForkTest } from "test/utils/BaseForkTest.sol";

contract AfCvxDepositForkTest is BaseForkTest {
    function test_deposit() public {
        uint256 assets = 10e18;
        address user = _createAccountWithCvx(assets);

        assertEq(CVX.balanceOf(user), assets);
        assertEq(CVX.balanceOf(address(afCvx)), 0);

        vm.startPrank(user);
        CVX.approve(address(afCvx), assets);
        uint256 shares = afCvx.deposit(assets, user);

        assertEq(CVX.balanceOf(user), 0);
        assertEq(CVX.balanceOf(address(afCvx)), assets);
        assertEq(afCvx.balanceOf(user), shares);
        assertEq(afCvx.totalAssets(), assets);
        assertEq(afCvx.totalSupply(), shares);
    }

    function test_mint() public {
        uint256 shares = 10e18;
        uint256 assets = afCvx.previewMint(shares);
        address user = _createAccountWithCvx(assets);

        assertEq(CVX.balanceOf(user), assets);
        assertEq(CVX.balanceOf(address(afCvx)), 0);

        vm.startPrank(user);
        CVX.approve(address(afCvx), assets);
        assets = afCvx.mint(shares, user);

        assertEq(CVX.balanceOf(user), 0);
        assertEq(CVX.balanceOf(address(afCvx)), assets);
        assertEq(afCvx.balanceOf(user), shares);
        assertEq(afCvx.totalAssets(), assets);
        assertEq(afCvx.totalSupply(), shares);
    }
}
