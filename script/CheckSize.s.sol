// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {DeepWood} from "../src/DeepWood.sol";

/// @notice Fail if DeepWood would not actually deploy.
///
/// EIP-170 caps runtime bytecode at 24,576 bytes. Nothing in the normal loop
/// checks this: `forge test` runs an oversized contract perfectly happily, and
/// a full green suite once hid a 2,302-byte overrun that only surfaced when
/// anvil refused the deployment with CreateContractSizeLimit.
///
/// Run: forge script script/CheckSize.s.sol --sig checkSize
contract CheckSize is Script {
    uint256 internal constant LIMIT = 24576;
    uint256 internal constant WARN_BELOW = 22000; // headroom worth complaining about

    function checkSize() external pure {
        uint256 size = type(DeepWood).creationCode.length;
        console.log("DeepWood creation code:", size, "bytes");
        if (size > LIMIT) {
            console.log("FAIL: exceeds the EIP-170 limit of", LIMIT);
            revert("DeepWood is undeployable");
        }
        if (size > WARN_BELOW) {
            console.log("WARN: under", LIMIT, "but with less than 2.5KB of headroom");
        }
        console.log("OK: deployable with", LIMIT - size, "bytes to spare");
    }
}
