// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Script, console} from "forge-std/Script.sol";
import {DeepWoodV3} from "../src/DeepWoodV3.sol";

/**
 * @notice Deploy DeepWoodV3 (settleBatch + migrateFromV2).
 *
 * Mirrors DeployV2's operational posture: HUNTER_ROLE = deployer, because a
 * hunter address whose key nobody holds ships a game nobody can open. The
 * seed must still be PUBLISHED before it is committed.
 *
 * Steps after deploy (in one broadcast so the address stays deterministic
 * in the log): optional seed commit, optional season open, optional V2
 * migration attestations. MIGRATE_* are comma lists, e.g.
 *   MIGRATE_PLAYERS=0xd1Bd...,0x...
 *   MIGRATE_TOOLS=0xd1Bd...:1:13       (player:tier:durability)
 *   MIGRATE_GEMS=0xd1Bd...:25:0:0:0:0  (player:c0:c1:c2:c3:c4)
 */
contract DeployV3 is Script {
    function run() external returns (DeepWoodV3 deployed) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address hunter = vm.envAddress("HUNTER_ADDRESS");

        require(treasury != address(0), "TREASURY_ADDRESS=0");
        require(hunter != address(0), "HUNTER_ADDRESS=0");
        if (treasury == hunter) {
            console.log("WARNING: treasury == hunter");
            console.log("  publish the seed before committing it, or it is unverifiable.");
        }

        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        if (expected != 0) {
            require(block.chainid == expected, "chain id mismatch");
        }

        console.log("deployer  :", vm.addr(pk));
        console.log("chain id  :", block.chainid);
        console.log("treasury  :", treasury);
        console.log("hunter    :", hunter);

        bytes32 seed = vm.envOr("SEASON_SEED", bytes32(0));
        bool openNow = vm.envOr("OPEN_SEASON", uint256(0)) == 1;

        vm.startBroadcast(pk);
        deployed = new DeepWoodV3(treasury, hunter);
        if (seed != bytes32(0)) {
            deployed.commitSeed(seed);
        }
        // Preseason is OPEN from the moment the seed commits; openSeason() is
        // for a numbered season and reverts AlreadyOpen on a preseason. Only
        // call it when the season is numbered AND closed.
        if (openNow) {
            (uint64 id, uint8 isPre,,,,,,,,) = deployed.current();
            if (isPre == 0 && !deployed.seasonOpen()) {
                deployed.openSeason();
            }
        }
        vm.stopBroadcast();

        console.log("DeepWoodV3 deployed at:", address(deployed));
    }
}
