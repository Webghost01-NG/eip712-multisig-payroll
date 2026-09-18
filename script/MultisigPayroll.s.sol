// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/MultisigPayroll.sol";

contract DeployMultisigPayroll is Script {
    function run() external returns (MultisigPayroll payroll) {
        vm.startBroadcast();

        address[] memory owners = new address[](3);
        owners[0] = address(0x1111111111111111111111111111111111111111);
        owners[1] = address(0x2222222222222222222222222222222222222222);
        owners[2] = address(0x3333333333333333333333333333333333333333);
        uint256 threshold = 2;

        payroll = new MultisigPayroll(owners, threshold);

        vm.stopBroadcast();
    }
}
