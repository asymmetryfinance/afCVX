// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

ICvxTreasury constant CVX_TREASURY = ICvxTreasury(address(0x1389388d01708118b497f59521f6943Be2541bb7));

interface ICvxTreasury {
    function withdrawTo(IERC20 asset, uint256 amount, address to) external;
}
