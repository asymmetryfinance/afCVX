// // SPDX-License-Identifier: MIT
// pragma solidity 0.8.25;

// import {LPStrategy} from "../../src/strategies/LPStrategy.sol";

// import "./Base.t.sol";

// contract LPTests is Base {

//     // ============================================================================================
//     // Setup
//     // ============================================================================================

//     function setUp() public override {
//         Base.setUp();

//         _upgradeImplementations();
//     }

//     // ============================================================================================
//     // Tests
//     // ============================================================================================

//     function testSwapFurnaceToLP() public {
//         uint256 _totalAssetsBefore = AFCVX_PROXY.totalAssets();
//         uint256 _maxTotalUnlockBefore = CLEVERCVXSTRATEGY_PROXY.maxTotalUnlock();
//         vm.prank(CLEVERCVXSTRATEGY_PROXY.operator());
//         CLEVERCVXSTRATEGY_PROXY.swapFurnaceToLP(1 ether, 0);
//         // assertEq(AFCVX_PROXY.totalAssets(), _totalAssetsBefore, "testSwapFurnaceToLP: E0");
//         assertEq(CLEVERCVXSTRATEGY_PROXY.maxTotalUnlock(), _maxTotalUnlockBefore, "testSwapFurnaceToLP: E1");
//         // console.log("LPStrategy.totalAssets():", CLEVERCVXSTRATEGY_PROXY.totalAssets());
//         // 2825039 12556356 6396979071
//         // 2825039 13934573 1900189543
//     }
// }