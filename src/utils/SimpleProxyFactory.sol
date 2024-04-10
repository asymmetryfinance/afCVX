// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { IProxySource } from "../interfaces/IProxySource.sol";
import { SimpleProxy } from "./SimpleProxy.sol";

/// @author philogy <https://github.com/philogy>
contract SimpleProxyFactory is IProxySource {
    address internal constant NO_IMPLEMENTATION = address(1);

    bytes32 public immutable PROXY_INIT_HASH = keccak256(type(SimpleProxy).creationCode);

    address public implementation = NO_IMPLEMENTATION;

    error NotSaltOwner();
    error InitCallFailed();

    function deployDeterministic(bytes32 salt, address initialImplementation, bytes memory initCall)
        external
        payable
        returns (address proxy)
    {
        address saltOwner = address(bytes20(salt));
        if (saltOwner != address(0) && saltOwner != msg.sender) revert NotSaltOwner();
        implementation = initialImplementation;
        proxy = address(new SimpleProxy{ salt: salt }());
        implementation = NO_IMPLEMENTATION;

        if (msg.value > 0 || initCall.length > 0) {
            (bool success,) = proxy.call{ value: msg.value }(initCall);
            if (!success) revert InitCallFailed();
        }
    }

    function predictDeterministicAddress(bytes32 salt) external view returns (address addr) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, PROXY_INIT_HASH)))));
    }
}
