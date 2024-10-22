// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "./Base.t.sol";

contract SimulateUnlockTests is Base {

    // address public user1 = 0x4f9ccE86D68Ee24275B9A2EDfC4eF52bd5e5b87c;
    // address public user2 = 0x76a1F47f8d998D07a15189a07d9aADA180E09aC6;
    address public user3 = 0xc42cEb990DeB305520C4527F2a841506095A55D6;

    function testSimulate() public {
        // vm.startPrank(owner);
        // CLEVERCVXSTRATEGY_PROXY.repay();
        // vm.roll(block.number + 1);
        // CLEVERCVXSTRATEGY_PROXY.unlock();
        // vm.stopPrank();

        // vm.roll(block.number + 1);
        // skip(1 weeks);

        vm.startPrank(user3);
        // AFCVX_PROXY.withdrawUnlocked(user3);
        // requestUnlock(uint256 _shares, address _receiver, address _owner)
        AFCVX_PROXY.approve(address(AFCVX_PROXY), uint256(AFCVX_PROXY.balanceOf(user3)));
        AFCVX_PROXY.requestUnlock(uint256(AFCVX_PROXY.balanceOf(user3)), user3, user3);
        vm.stopPrank();

        console.log("user balance:", uint256(AFCVX_PROXY.balanceOf(user3)));

        // CleverCvxStrategy.UnlockRequest[] memory unlocks = CLEVERCVXSTRATEGY_PROXY.getRequestedUnlocks(user3);
        // console.log("unlocks length:", uint256(unlocks.length));
        // for (uint256 i = 0; i < unlocks.length; i++) {
        //     console.log("amount:", uint256(unlocks[i].unlockAmount));
        //     console.log("epoch:", uint256(unlocks[i].unlockEpoch));
        // }

        // Args: AttributeDict({'sender': '0xc42cEb990DeB305520C4527F2a841506095A55D6', 'receiver': '0xc42cEb990DeB305520C4527F2a841506095A55D6', 'owner': '0xc42cEb990DeB305520C4527F2a841506095A55D6', 'assets': 1000000000000000000, 'shares': 1003842333477559275, 'unlockEpoch': 2852})
        // Transaction Hash: 0xda93a2421b5653b5bd98921bc39fc227159355c4cce7447bdce55ff343708853
        // Block Number: 19821203

        // Event: UnlockedWithdrawn
        // Args: AttributeDict({'sender': '0xc42cEb990DeB305520C4527F2a841506095A55D6', 'receiver': '0xc42cEb990DeB305520C4527F2a841506095A55D6', 'amount': 1000000000000000000})
        // Transaction Hash: 0xf3f76240fc8b5133ed305d1ebfeb065dab05780c9277b753eedfbf73c5e46c6e
        // Block Number: 20644036

        // vm.prank(user2);
        // AFCVX_PROXY.withdrawUnlocked(user2);
    }
}