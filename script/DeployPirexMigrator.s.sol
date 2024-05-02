// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {PirexMigrator} from "../src/PirexMigrator.sol";

import "forge-std/Script.sol";
import "forge-std/console.sol";

// ---- Usage ----

// deploy:
// forge script script/DeployPirexMigrator.s.sol:DeployPirexMigrator --verify --slow --legacy --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

// verify:
// --constructor-args $(cast abi-encode "constructor(address)" 0x5C1E6bA712e9FC3399Ee7d5824B6Ec68A0363C02)
// forge verify-contract --etherscan-api-key $KEY --watch --chain-id $CHAIN_ID --compiler-version $FULL_COMPILER_VER --verifier-url $VERIFIER_URL $ADDRESS $PATH:$FILE_NAME

contract DeployPirexMigrator is Script {

    function run() public {

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        // Deploy PirexMigrator
        address _migrator = address(new PirexMigrator());

        vm.stopBroadcast();

        console.log("=====================================");
        console.log("=====================================");
        console.log("PirexMigrator: ", _migrator);
        console.log("=====================================");
        console.log("=====================================");

    }
}

// =====================================
// =====================================
// PirexMigrator:  0xDd737dADA46F3A111074dCE29B9430a7EA000092
// =====================================
// =====================================