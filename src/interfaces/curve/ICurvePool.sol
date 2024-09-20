// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface ICurvePool {
    function add_liquidity(uint256[2] memory _amounts, uint256 _min_mint_amount) external returns (uint256);
    function remove_liquidity_one_coin(uint256 _burn_amount, int128 i, uint256 _min_received, address _receiver) external returns (uint256);
    function get_balances() external view returns (uint256[2] memory);
    function balanceOf(address _account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}