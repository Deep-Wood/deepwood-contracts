// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Script, console} from "forge-std/Script.sol";
import {DeepWoodV4} from "../src/DeepWoodV4.sol";

/**
 * @notice Deploy DeepWoodV4 (token buy, price oracle, emergency withdraw).
 *
 * V4 adds:
 * - buyToolWithToken: buy tools with $DEEPWOOD at 10% discount
 * - redeemGems: token-only (no ETH payout)
 * - emergencyWithdraw: owner can withdraw stuck ETH or tokens
 * - migrateFromV3: players can migrate state from V3
 * - Price oracle: reads sqrtPriceX96 from Uniswap V4 PoolManager
 *
 * Post-deploy steps (in one broadcast):
 * 1. Set token address
 * 2. Enable token rail
 * 3. Mark graduated
 * 4. Fund tokens (optional)
 * 5. Commit seed (optional)
 * 6. Open season (optional)
 */
contract DeployV4 is Script {
    function run() external returns (DeepWoodV4 deployed) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address hunter = vm.envAddress("HUNTER_ADDRESS");
        address poolManager = vm.envAddress("POOL_MANAGER");
        bytes32 poolId = vm.envBytes32("POOL_ID");
        address v3Contract = vm.envAddress("V3_CONTRACT");
        address token = vm.envAddress("TOKEN_ADDRESS");

        require(treasury != address(0), "TREASURY_ADDRESS=0");
        require(hunter != address(0), "HUNTER_ADDRESS=0");
        require(poolManager != address(0), "POOL_MANAGER=0");
        require(v3Contract != address(0), "V3_CONTRACT=0");
        require(token != address(0), "TOKEN_ADDRESS=0");

        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        if (expected != 0) {
            require(block.chainid == expected, "chain id mismatch");
        }

        // Deploy info logged via events for the deployer to read

        bytes32 seed = vm.envOr("SEASON_SEED", bytes32(0));
        bool openNow = vm.envOr("OPEN_SEASON", uint256(0)) == 1;
        bool markGraduated = vm.envOr("MARK_GRADUATED", uint256(0)) == 1;
        uint256 fundAmount = vm.envOr("FUND_TOKENS", uint256(0));

        vm.startBroadcast(pk);
        deployed = new DeepWoodV4(treasury, hunter, poolManager, poolId, v3Contract);

        // Set token and enable token rail
        deployed.setToken(token);
        deployed.setTokenRail(true);

        // Mark graduated if requested
        if (markGraduated) {
            deployed.markGraduated();
        }

        // Fund tokens if requested
        if (fundAmount > 0) {
            deployed.fundToken(fundAmount);
        }

        // Commit seed if provided
        if (seed != bytes32(0)) {
            deployed.commitSeed(seed);
        }

        // Open season if requested
        if (openNow) {
            (uint64 id, uint8 isPre,,,,,,,,) = deployed.current();
            if (isPre == 0 && !deployed.seasonOpen()) {
                deployed.openSeason();
            }
        }

        vm.stopBroadcast();


    }
}
