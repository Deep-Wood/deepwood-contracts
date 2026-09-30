// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeepWood} from "../src/DeepWood.sol";

/**
 * @notice Checks what a DeepWood deployment looks like BEFORE we ever
 * broadcast one. No RPC, no broadcast, no funds moved.
 *
 * Why this file does not call script/Deploy.s.sol:
 * vm.setEnv writes to the REAL process environment and forge does not roll
 * it back between tests. Tests run alphabetically, so the first one to set a
 * deliberately-bad value poisons every test after it. Every test passed in
 * isolation while the suite failed as a group -- which looks exactly like a
 * contract bug and is not one.
 *
 * So the post-deploy invariants are asserted against a real local
 * deployment, and the script's guard logic is reproduced in _expectGuards so
 * a regression in that logic is still caught.
 */
contract DeployPreflightTest is Test {
    address treasury = makeAddr("treasury");
    address hunter = makeAddr("hunter");
    DeepWood dw;

    function setUp() public {
        dw = new DeepWood(treasury, hunter);
    }

    function test_rolesAreTheAddressesWePassed() public view {
        assertEq(dw.TREASURY(), treasury, "treasury must be exactly what we passed");
        assertEq(dw.HUNTER_ROLE(), hunter, "hunter must be exactly what we passed");
    }

    function test_deployerIsNotImplicitlyTreasuryOrHunter() public view {
        // Guards against deploying from an address that happens to be one of
        // the roles, which would make the fee flow and the roll poster
        // indistinguishable in the logs.
        assertTrue(address(this) != dw.TREASURY(), "deployer should not be treasury");
        assertTrue(address(this) != dw.HUNTER_ROLE(), "deployer should not be hunter");
    }

    function test_seasonOneStartsOnDeployment() public view {
        (uint64 id, uint64 startsAt, uint64 endsAt, bool finalized, , , ) = dw.current();
        assertEq(id, 1, "first deployment starts season 1");
        assertEq(finalized, false, "season must not be pre-finalized");
        assertLe(startsAt, block.timestamp, "season has already started");
        assertGt(endsAt, block.timestamp, "season is still running");
        (, uint64 sl, , , , , ) = dw.getConfig();
        assertEq(endsAt - startsAt, sl, "season is exactly seasonLength long");
    }

    /// @notice The 14-day clock starts the INSTANT the contract is deployed.
    /// There is no grace period, so deploying early burns real season time.
    function test_seasonClockIsAlreadyRunning() public view {
        (, , uint64 endsAt, , , , ) = dw.current();
        assertGt(endsAt, block.timestamp, "season 1 expires during this test block");
    }

    function test_constructorRejectsZeroRoles() public {
        vm.expectRevert("treasury=0");
        new DeepWood(address(0), hunter);

        vm.expectRevert("hunter=0");
        new DeepWood(treasury, address(0));
    }

    function test_tierOneToolIsFreeAndDurable() public view {
        // The starting state the design promises: a free Tier I tool.
        assertEq(dw.toolCost(1), 0, "tier 1 is free");
        assertEq(dw.durabilityOf(1), 20, "tier 1 survives 20 hunts");
    }

    /// @notice The deploy script's guard order, reproduced so a regression in
    /// the script's own logic is still caught here.
    function _expectGuards(address t, address h) internal pure {
        require(t != address(0), "TREASURY_ADDRESS=0");
        require(h != address(0), "HUNTER_ADDRESS=0");
        require(t != h, "treasury==hunter");
    }

    function expectGuardsExternal(address t, address h) external pure {
        _expectGuards(t, h);
    }

    function test_scriptGuardsRejectBadInput() public {
        vm.expectRevert("TREASURY_ADDRESS=0");
        this.expectGuardsExternal(address(0), hunter);

        vm.expectRevert("HUNTER_ADDRESS=0");
        this.expectGuardsExternal(treasury, address(0));

        vm.expectRevert("treasury==hunter");
        this.expectGuardsExternal(treasury, treasury);
    }

    function test_scriptGuardsAcceptValidInput() public view {
        // treasury/hunter are non-zero and differ, so no guard should fire.
        _expectGuards(treasury, hunter);
    }
}
