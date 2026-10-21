// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {LastSeenRegistry} from "../src/LastSeenRegistry.sol";
import {IIntake} from "../src/IIntake.sol";

/// Robinhood Chain values from https://api.imd.fun/requests/capabilities (read 14 Oct 2026). Re-read them before deploying.
contract Deploy is Script {
    function run() external returns (LastSeenRegistry reg) {
        address owner = vm.envAddress("REGISTRY_OWNER");
        vm.startBroadcast();
        reg = new LastSeenRegistry(
            owner,
            IIntake(0xa43e6F75ee006411F79Ac1C84120606C2330DE82),          // Intake
            0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000, // "oracle.request@oracle-1"
            IERC20(0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127),          // IMD on Robinhood Chain
            0.5 ether,                                                   // 0.5 IMD per question
            0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982                   // oracle attester
        );
        vm.stopBroadcast();
    }
}
