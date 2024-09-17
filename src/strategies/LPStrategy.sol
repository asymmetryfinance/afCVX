// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Ownable} from "solady/auth/Ownable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract LPStrategy is Ownable, UUPSUpgradeable {

    // ============================================================================================
    // Constructor
    // ============================================================================================

    constructor() {
        _disableInitializers();
    }

    // ============================================================================================
    // Owner functions
    // ============================================================================================

    function _authorizeUpgrade(address /* newImplementation */ ) internal view override onlyOwner {}

    // ============================================================================================
    // View functions
    // ============================================================================================

    // this assumes clevcvx == cvx
    function totalAssets() external view returns (uint256) {
        // return LP.balanceOf(address(this)) * LP.totalAssets() / LP.totalSupply();
        return 0;
    }
}