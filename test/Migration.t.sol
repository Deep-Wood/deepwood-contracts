// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {DeepWoodV4} from "../src/DeepWoodV4.sol";

/// @dev Minimal V3-shaped contract: the only surface migrateFromV3 touches.
///      Keeping it a mock means this test pins the CONTRACT between the two
///      versions, not the shape of the real V3 deployment.
contract MockV3 {
    mapping(address => uint256[6]) public statsOf;
    mapping(address => uint8) public toolTierOf;
    mapping(address => uint64) public toolDurOf;
    mapping(address => bool) public toolActiveOf;
    mapping(address => uint256) public seasonScoreOf;
    mapping(address => uint8) public skillOf;
    mapping(address => mapping(uint8 => uint256)) public gemsOf;

    function seed(
        address player,
        uint256[6] memory stats,
        uint8 tier,
        uint64 dur,
        bool active,
        uint256 score,
        uint8 skill,
        uint256[5] memory gems
    ) external {
        statsOf[player] = stats;
        toolTierOf[player] = tier;
        toolDurOf[player] = dur;
        toolActiveOf[player] = active;
        seasonScoreOf[player] = score;
        skillOf[player] = skill;
        for (uint8 i = 0; i < 5; i++) gemsOf[player][i] = gems[i];
    }

    function playerStats(address p)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint64)
    {
        uint256[6] memory s = statsOf[p];
        return (s[0], s[1], s[2], s[3], s[4], uint64(s[5]));
    }

    function toolOf(address p) external view returns (uint8, uint64, bool) {
        return (toolTierOf[p], toolDurOf[p], toolActiveOf[p]);
    }

    function seasonScore(address p) external view returns (uint256) {
        return seasonScoreOf[p];
    }

}

/**
 * @notice The V3 -> V4 migration, and the owner gem credit.
 *
 * The regression this file exists to prevent: the first V4 deploy shipped
 * migrateFromV3 that copied the player's stats, tool, score and skill but NOT
 * their satchel. Migrated players arrived with 28 hunts, a score of 137 and an
 * empty inventory -- the gems they could actually spend stayed stranded on V3.
 * A test suite that only asserted on stats would have called that migration a
 * success, which is precisely what happened.
 */
contract MigrationTest is Test {
    bytes32 internal constant SEED = keccak256("deepwood-preseason");
    bytes32 internal constant POOL_ID = keccak256("pool");

    MockV3 v3;
    DeepWoodV4 dw;

    address owner = address(this);
    address treasury = makeAddr("treasury");
    address hunter = makeAddr("hunter");
    address poolManager = makeAddr("poolManager");
    address alice = makeAddr("alice");
    address rando = makeAddr("rando");

    function setUp() public {
        v3 = new MockV3();
        dw = new DeepWoodV4(treasury, hunter, poolManager, POOL_ID, address(v3));
        vm.prank(hunter);
        dw.commitSeed(SEED);
    }

    /// @dev The exact trader2 shape: tier 1 Wood with 5/20 durability left,
    ///      28 hunts, score 137, and 128 Quartz on V3.
    function _seedV3Player(address player) internal {
        uint256[6] memory stats = [uint256(0), 0, 9, 0.00005 ether, 0, 28];
        uint256[5] memory gems = [uint256(128), 0, 0, 0, 0];
        v3.seed(player, stats, 1, 5, true, 137, 0, gems);
    }

    function test_MigrationCopiesTheSatchel() public {
        _seedV3Player(alice);

        dw.migrateFromV3(alice);

        assertEq(dw.gemsOf(alice, DeepWoodV4.Rarity(0)), 128, "Quartz must survive the migration");
        assertEq(dw.gemsOf(alice, DeepWoodV4.Rarity(1)), 0);
        assertEq(dw.gemsOf(alice, DeepWoodV4.Rarity(4)), 0);
    }

    function test_MigrationCopiesEveryRarity() public {
        uint256[6] memory stats = [uint256(0), 0, 9, 0.00005 ether, 0, 28];
        uint256[5] memory gems = [uint256(10), 20, 30, 40, 50];
        v3.seed(alice, stats, 1, 5, true, 137, 0, gems);

        dw.migrateFromV3(alice);

        assertEq(dw.gemsOf(alice, DeepWoodV4.Rarity(0)), 10);
        assertEq(dw.gemsOf(alice, DeepWoodV4.Rarity(1)), 20);
        assertEq(dw.gemsOf(alice, DeepWoodV4.Rarity(2)), 30);
        assertEq(dw.gemsOf(alice, DeepWoodV4.Rarity(3)), 40);
        assertEq(dw.gemsOf(alice, DeepWoodV4.Rarity(4)), 50);
    }

    function test_MigrationLeavesZeroRaritiesAlone() public {
        uint256[6] memory stats = [uint256(0), 0, 9, 0.00005 ether, 0, 28];
        uint256[5] memory gems = [uint256(0), 0, 0, 0, 0];
        v3.seed(alice, stats, 1, 5, true, 0, 0, gems);

        dw.migrateFromV3(alice);

        for (uint8 i = 0; i < 5; i++) {
            assertEq(dw.gemsOf(alice, DeepWoodV4.Rarity(i)), 0, "a zero V3 slot stays zero");
        }
    }

    /// @notice Stats AND satchel: the migration is one transaction, so it has to
    ///         deliver both halves. Asserting only the satchel would let a future
    ///         edit drop the stats copy again.
    function test_MigrationIsAtomicAcrossStatsAndSatchel() public {
        _seedV3Player(alice);

        dw.migrateFromV3(alice);

        (uint256 earned,,,,, uint64 hunts) = dw.playerStats(alice);
        assertEq(hunts, 28, "hunts migrate");
        assertEq(dw.seasonScore(alice), 137, "score migrates");
        (uint8 tier, uint64 dur,) = dw.toolOf(alice);
        assertEq(tier, 1, "tool tier migrates");
        assertEq(dur, 5, "tool durability migrates");
        assertEq(dw.gemsOf(alice, DeepWoodV4.Rarity(0)), 128, "satchel migrates");
        earned; // silence unused-variable on the first tuple element
    }

    function test_AnyoneCanMigrate() public {
        _seedV3Player(alice);

        vm.prank(rando);
        dw.migrateFromV3(alice);

        assertEq(dw.gemsOf(alice, DeepWoodV4.Rarity(0)), 128);
    }

    function test_CompletedMigrationBlocksFurtherMigrations() public {
        _seedV3Player(alice);
        dw.migrateFromV3(alice);

        dw.completeMigration();

        _seedV3Player(rando);
        vm.expectRevert();
        dw.migrateFromV3(rando);
    }

    // ---- grantGems --------------------------------------------------------

    function test_GrantGemsCreditsThePlayer() public {
        dw.grantGems(alice, 0, 128);

        assertEq(dw.gemsOf(alice, DeepWoodV4.Rarity(0)), 128, "gems land in the satchel");
        (uint256 earned,,,,,) = dw.playerStats(alice);
        assertGt(earned, 0, "the grant also counts as earned, so ROI sees it");
    }

    function test_GrantGemsIsAdditive() public {
        dw.grantGems(alice, 0, 128);
        dw.grantGems(alice, 0, 1);

        assertEq(dw.gemsOf(alice, DeepWoodV4.Rarity(0)), 129, "repeated grants accumulate");
    }

    function test_GrantGemsCannotConfiscate() public {
        dw.grantGems(alice, 2, 7);
        dw.grantGems(alice, 0, 128);

        assertEq(dw.gemsOf(alice, DeepWoodV4.Rarity(2)), 7, "crediting one rarity never touches another");
    }

    function test_NonOwnerCannotGrantGems() public {
        vm.prank(rando);
        vm.expectRevert();
        dw.grantGems(alice, 0, 128);
    }

    function test_GrantGemsRejectsAZeroPlayer() public {
        vm.expectRevert();
        dw.grantGems(address(0), 0, 128);
    }

    function test_GrantGemsRejectsAnUnknownRarity() public {
        vm.expectRevert();
        dw.grantGems(alice, 5, 128);
    }

    /// @notice The exact repair the live contract needs: credit the 128 Quartz
    ///         the broken migration stranded on V3, and prove the player ends up
    ///         able to spend them.
    function test_GrantRestoresAStrandedSatchel() public {
        _seedV3Player(alice);

        // What the buggy migration left behind: stats yes, satchel no.
        dw.migrateFromV3(alice);
        // (with the fix this already has the gems, so assert the shape instead)
        assertEq(dw.gemsOf(alice, DeepWoodV4.Rarity(0)), 128, "the fixed migration already restored it");

        // The owner repair path, for a player migrated by the OLD contract:
        // grant on top of an empty satchel and confirm the total is right.
        address stranded = makeAddr("stranded");
        dw.grantGems(stranded, 0, 128);
        assertEq(dw.gemsOf(stranded, DeepWoodV4.Rarity(0)), 128, "grant alone also restores a lost satchel");
    }
}
