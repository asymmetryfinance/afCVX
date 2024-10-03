// // SPDX-License-Identifier: MIT
// pragma solidity 0.8.25;

// import "./Base.t.sol";

// contract SimulateUnlockTests is Base {

//     address public user1 = 0x4f9ccE86D68Ee24275B9A2EDfC4eF52bd5e5b87c;
//     address public user2 = 0x76a1F47f8d998D07a15189a07d9aADA180E09aC6;

//     function testSimulate() public {
//         vm.startPrank(owner);
//         CLEVERCVXSTRATEGY_PROXY.repay();
//         vm.roll(block.number + 1);
//         CLEVERCVXSTRATEGY_PROXY.unlock();
//         vm.stopPrank();

//         vm.roll(block.number + 1);
//         skip(1 weeks);

//         vm.prank(user1);
//         AFCVX_PROXY.withdrawUnlocked(user1);

//         vm.prank(user2);
//         AFCVX_PROXY.withdrawUnlocked(user2);
//     }
// }