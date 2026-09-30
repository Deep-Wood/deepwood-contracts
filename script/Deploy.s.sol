// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {DeepWood} from "../src/DeepWood.sol";

/**
 * @notice Deploy DeepWood.
 *
 *   forge script script/Deploy.s.sol:Deploy --rpc-url <RPC> --broadcast
 *
 * Two constructor arguments are required and both are permanent -- TREASURY
 * and HUNTER_ROLE are `immutable`, so a wrong value here cannot be patched
 * later. It means re-deploying.
 *
 * Required env:
 *   PRIVATE_KEY      deployer key (must be funded on the target chain)
 *   TREASURY_ADDRESS  receives the 5% fee
 *   HUNTER_ADDRESS    the only address allowed to post rolls
 *
 * Optional:
 *   EXPECTED_CHAIN_ID  guard. If set and it does not match the live chain id
 *                      the script reverts. This is a safety rail against
 *                      broadcasting a testnet deploy to mainnet (or the
 *                      reverse) via a stale --rpc-url.
 *
 *   GAME_TOKEN          the launched token to point the game at. If set, the
 *                      script calls setToken() so redemption has an address to
 *                      pay through. The rail itself is deliberately left
 *                      DISABLED: tokenRedemptionActive() also requires
 *                      markGraduated() plus the graduation grace, so a live
 *                      rail cannot pay out before graduation even if flipped
 *                      later. Wire it here, arm it deliberately at graduation.
 *
 * NOTE: deploying starts season 1 immediately -- _startSeason(1) stamps
 * startsAt from block.timestamp. There is no grace period before the 14-day
 * clock is running.
 */
contract Deploy is Script {
    function run() external returns (DeepWood deployed) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address hunter = vm.envAddress("HUNTER_ADDRESS");
        address gameToken = vm.envOr("GAME_TOKEN", address(0));

        // Refuse the two degenerate cases before spending gas.
        require(treasury != address(0), "TREASURY_ADDRESS=0");
        require(hunter != address(0), "HUNTER_ADDRESS=0");

        // A treasury that is also the hunter means the fee and the roll
        // poster are the same party, which defeats the point of the split.
        require(treasury != hunter, "treasury==hunter");

        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        if (expected != 0) {
            uint256 live = block.chainid;
            require(live == expected, "chain id mismatch");
            console.log("chain id confirmed:", live);
        }

        console.log("deployer  :", vm.addr(pk));
        console.log("chain id  :", block.chainid);
        console.log("treasury  :", treasury);
        console.log("hunter    :", hunter);
        if (gameToken == address(0)) {
            console.log("token     : (none)");
        } else {
            console.log("token     :", gameToken);
        }

        vm.startBroadcast(pk);
        deployed = new DeepWood(treasury, hunter);
        if (gameToken != address(0)) {
            // Point the game at the token. The rail stays OFF on purpose --
            // arming it is a deliberate post-graduation action.
            deployed.setToken(gameToken);
        }
        vm.stopBroadcast();

        console.log("DeepWood deployed at:", address(deployed));
        console.log("owner              :", deployed.owner());
        console.log("token wired        :", deployed.token());
        console.log("token rail enabled :", deployed.tokenRailEnabled());
        (, uint64 seasonLength,, , , , ) = deployed.getConfig();
        console.log("season 1 ends at   :", block.timestamp + seasonLength);
    }
}
