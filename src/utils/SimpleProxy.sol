// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { Proxy } from "@openzeppelin/contracts/proxy/Proxy.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { IProxySource } from "./interfaces/IProxySource.sol";

/// @author philogy <https://github.com/philogy>
/// @dev ERC1967 Proxy that has no initcall or implementation factor in its deploy bytecode.
contract SimpleProxy is Proxy {
    constructor() {
        address implementation = IProxySource(msg.sender).implementation();
        ERC1967Utils.upgradeToAndCall(implementation, new bytes(0));
    }

    function _implementation() internal view override returns (address) {
        return ERC1967Utils.getImplementation();
    }
}
