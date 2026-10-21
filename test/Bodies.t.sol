// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {LastSeenRegistry} from "../src/LastSeenRegistry.sol";
import {MockIMD, MockIntake} from "./LastSeenRegistry.t.sol";

/// Prints the exact questions the swarm will read, so they can be sent to IdentityMD's free /requests/check.
contract BodiesTest is Test {
    function test_printBodies() public {
        MockIMD imd = new MockIMD();
        MockIntake intake = new MockIntake();
        LastSeenRegistry reg = new LastSeenRegistry(address(this), intake, bytes32("oracle.request@oracle-1"), IERC20(address(imd)), 0.5 ether, address(1));
        imd.mint(address(this), 100 ether);
        imd.approve(address(reg), type(uint256).max);
        uint256 id = reg.openCase(vm.parseAddress("0xc6525dbbc9ac18fbf9ec93c219670b0dbb6cf2d3"), address(0xEF94), 8453, 20000000, 20100000);
        reg.postBounty(id, 1 ether, 2, 0, 30);
        reg.submitLink(id, "https://x.com/someone/status/1234567890");
        console2.log(string(intake.lastBody()));
        reg.requestAudit(8453, vm.parseAddress("0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"));
        console2.log(string(intake.lastBody()));
    }
}
