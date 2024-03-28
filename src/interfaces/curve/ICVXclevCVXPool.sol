// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

ICVXclevCVXPool constant CVX_CLEVCVX_POOL = ICVXclevCVXPool(payable(0xF9078Fb962A7D13F55d40d49C8AA6472aBD1A5a6));

int128 constant CVX_INDEX = 0;
int128 constant CLEVCVX_INDEX = 1;

// solhint-disable var-name-mixedcase, func-name-mixedcase
interface ICVXclevCVXPool {
    function exchange(int128 i, int128 j, uint256 _dx, uint256 _min_dy, address _receiver) external returns (uint256);

    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}
