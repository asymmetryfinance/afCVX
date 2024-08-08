// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IFurnace {
    function getUserInfo(address _account) external view returns (uint256 unrealised, uint256 realised);
    function deposit(uint256 _amount) external;
    function depositFor(address _account, uint256 _amount) external;
    function withdraw(address _recipient, uint256 _amount) external;
    function withdrawAll(address _recipient) external;
    function claim(address _recipient) external;
    function exit(address _recipient) external;
    function distribute(address _origin, uint256 _amount) external;
}
