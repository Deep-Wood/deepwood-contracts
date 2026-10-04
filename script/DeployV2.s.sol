// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {DeepWoodV2} from "../src/DeepWoodV2.sol";

/**
 * @notice Deploy DeepWoodV2.
 *
 *   forge script script/DeployV2.s.sol:DeployV2 --rpc-url <RPC> --broadcast
 *
 * WHY THIS IS A SEPARATE SCRIPT
 * =============================
 * `Deploy.s.sol` imports DeepWood.sol, so running it would have broadcast V1
 * again and overwritten deployments/testnet-46630.json with a V1 address while
 * the client spoke the V2 ABI. There was no V2 deploy path at all, which is why
 * V2 sat undeployed through a fully green test suite. Editing Deploy.s.sol
 * in place would have quietly changed what "deploy" means for anyone running
 * the old command against an old expectations file; a distinct entry point
 * makes the version explicit at the call site.
 *
 * Constructor arguments are PERMANENT -- TREASURY and HUNTER_ROLE are
 * `immutable`, so a wrong value means re-deploying.
 *
 * Required env:
 *   PRIVATE_KEY      deployer key (funded on the target chain)
 *   TREASURY_ADDRESS  receives the 5% tool fee
 *   HUNTER_ADDRESS    the only address allowed to commit a seed
 *
 * Optional:
 *   EXPECTED_CHAIN_ID  guard against broadcasting to the wrong chain via a
 *                      stale --rpc-url
 *   SEASON_SEED       the preseason seed. Publishing it must happen BEFORE the
 *                     seed is committed or "committed before anyone acted on
 *                     it" means nothing. Left unset, the game deploys with the
 *                     seed uncommitted and NOT open: one `commitSeed` call
 *                     later turns it on. That single deliberate owner call is
 *                     the only thing between a fresh deploy and a playable one.
 *   OPEN_SEASON       1 to call openSeason() in the same broadcast. Refuses
 *                     without a seed, by design.
 */
contract DeployV2 is Script {
    function run() external returns (DeepWoodV2 deployed) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address hunter = vm.envAddress("HUNTER_ADDRESS");

        // Refuse the degenerate cases before spending gas.
        require(treasury != address(0), "TREASURY_ADDRESS=0");
        require(hunter != address(0), "HUNTER_ADDRESS=0");
        // V1 hard-required treasury != hunter. That guard is a WARNING here,
        // not a revert, and the reason is operational rather than principled.
        //
        // `commitSeed` is gated on HUNTER_ROLE, so if HUNTER_ROLE is an address
        // whose key nobody holds, the seed can NEVER be committed and the game
        // is permanently unopenable. The previous deployment used a separate
        // hunter address (0xfE01...) whose key is not in .deploy.env, so reusing
        // it here would ship a game nobody could start.
        //
        // The deployer key IS held, so HUNTER_ROLE = deployer is the only choice
        // that yields a playable game. It also means one party holds both
        // roles: it receives the 5% tool fee AND commits the season seed. That
        // is a real centralisation cost and it is why the seed must be
        // PUBLISHED before it is committed -- a committed seed the fee
        // recipient chose, and never revealed, is not verifiable at all.
        if (treasury == hunter) {
            console.log("WARNING: treasury == hunter");
            console.log("  one party receives the tool fee AND commits the seed.");
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
        deployed = new DeepWoodV2(treasury, hunter);
        if (seed != bytes32(0)) {
            deployed.commitSeed(seed);
        }
        if (openNow) {
            deployed.openSeason();
        }
        vm.stopBroadcast();

        console.log("DeepWoodV2 deployed at:", address(deployed));
        console.log("phase                 :", uint256(deployed.phase()));
        console.log("preseason paused      :", deployed.preseasonPaused());
        console.log("seed committed        :", deployed.seasonSeed() != bytes32(0));
        console.log("season open           :", deployed.seasonOpen());
        // previewHunt is a post-deploy sanity read, but it REVERTS with
        // SeedNotCommitted while no seed is set -- the contract correctly
        // refuses to preview a hunt it cannot verify. So it is only read when a
        // seed was actually committed in this broadcast.
        //
        // `address(this)` is banned inside a script (the contract is ephemeral,
        // so its address is meaningless), hence vm.addr(pk) as a stand-in.
        if (seed != bytes32(0)) {
            (uint256[5] memory previewCounts,) = deployed.previewHunt(vm.addr(pk), 1);
            console.log("previewHunt reachable :", previewCounts[0] > 0);
        } else {
            console.log("previewHunt reachable : (needs a committed seed)");
        }
    }
}
