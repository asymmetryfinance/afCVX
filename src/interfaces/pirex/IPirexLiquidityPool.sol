// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

address constant _CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
address constant _PX_CVX = 0x389fB29230D02e67eB963C1F5A00f2b16f95BEb7;

interface IPirexLiquidityPool {

    // Enumeration for the token swap
    enum Token {
        _CVX,
        _PX_CVX
    }

    /** 
        @notice Swap the specified amount of source token into the counterpart token via the curvePool
        @param  source       enum     Source token
        @param  amount       uint256  Amount of source token
        @param  minReceived  uint256  Minimum received amount of counterpart token
        @param  fromIndex    uint256  Index of the source token
        @param  toIndex      uint256  Index of the counterpart token
     */
    function swap(Token source, uint256 amount, uint256 minReceived, uint256 fromIndex, uint256 toIndex) external;
}