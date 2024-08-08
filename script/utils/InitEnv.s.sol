// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {AfCvx} from "../../src/AfCvx.sol";
import {CleverCvxStrategy} from "../../src/strategies/CleverCvxStrategy.sol";

import "forge-std/Script.sol";
import "forge-std/console.sol";

// ---- Usage ----

// deploy:
// forge script script/utils/InitEnv.s.sol:InitEnv --slow --rpc-url $RPC_URL --broadcast

contract InitEnv is Script {

    address public immutable owner = 0x263b03BbA0BbbC320928B6026f5eAAFAD9F1ddeb;

    AfCvx public afCvxImplementation;
    CleverCvxStrategy public cleverCvxStrategyImplementation;

    AfCvx public constant AFCVX_PROXY = AfCvx(payable(address(0x8668a15b7b023Dc77B372a740FCb8939E15257Cf)));
    CleverCvxStrategy public constant CLEVERCVXSTRATEGY_PROXY = CleverCvxStrategy(address(0xB828a33aF42ab2e8908DfA8C2470850db7e4Fd2a));

    function run() public {
        afCvxImplementation = AfCvx(payable(0x56664FFcCfF6BB282CcA96808AF03d9042e1f799));
        cleverCvxStrategyImplementation = CleverCvxStrategy(0xD0F77441B70c84aa3366a9F79F2fD16618739aB0);

        _upgradeImplementations();
    }

    function _upgradeImplementations() internal {
        bytes memory emptyData = "";
        vm.startPrank(owner);
        UUPSUpgradeable(AFCVX_PROXY).upgradeToAndCall(address(afCvxImplementation), emptyData);
        UUPSUpgradeable(CLEVERCVXSTRATEGY_PROXY).upgradeToAndCall(address(cleverCvxStrategyImplementation), emptyData);
        vm.stopPrank();
    }
}