/**
 * DeepWood off-chain hunt engine.
 *
 * The hunt runs OFF-CHAIN (it must feel like a web2 game) and settles
 * ON-CHAIN. This file owns the part that could cheat: deciding what a player
 * finds. See R5 in SPEC.md -- the hunter may DELAY a result, never INFLATE it.
 *
 * The defence is two-part and both parts are implemented here:
 *
 *   1. COMMIT BEFORE HUNT. At the start of a season the engine derives a
 *      merkle root over every (player, huntIndex) leaf it will later settle.
 *      That root is published on-chain via commitSeason(). Because the root
 *      covers hunt indices the engine has not rolled yet, it cannot be
 *      rewritten after players see results -- it would have to re-derive the
 *      whole season.
 *
 *   2. ROLLS ARE SEEDED AND DETERMINISTIC. Every result comes from
 *      keccak256(seed, player, huntIndex, toolTier), so a result is
 *      reproducible by anyone holding the seed. Publishing the seed after the
 *      season lets players re-derive and verify every leaf in the root.
 *
 * What this does NOT give: the engine could simply refuse to call
 * settleHunt. That is a liveness failure, not a safety one, and it is
 * documented as a real centralisation rather than hidden.
 */
import sha3 from 'js-sha3';
const { keccak256 } = sha3;

export const RARITY = { COMMON: 0, UNCOMMON: 1, RARE: 2, EPIC: 3, LEGENDARY: 4 };
export const RARITY_NAME = ['Quartz', 'Amber', 'Sapphire', 'Ruby', 'Diamond'];

/** Mirrors DeepWood.dropTable(). Index = rarity, denominator 10_000. */
export const DROP_TABLE = {
  1: [9000, 1000, 0, 0, 0],
  2: [7000, 2500, 500, 0, 0],
  3: [5500, 3000, 1200, 300, 0],
  4: [4000, 3000, 2000, 900, 100],
};

/** Mirrors DeepWood.priceOf(). Wei. */
export const PRICE = {
  0: 50_000_000_000_000n, // 0.00005 ETH  Quartz
  1: 400_000_000_000_000n, // 0.0004 ETH   Amber
  2: 3_000_000_000_000_000n, // 0.003 ETH   Sapphire
  3: 25_000_000_000_000_000n, // 0.025 ETH   Ruby
  4: 200_000_000_000_000_000n, // 0.2 ETH    Diamond
};

/**
 * REAL keccak256 -- the same function the contract uses.
 *
 * This was sha256 in the first version, which was a genuine correctness bug,
 * not a naming nit: a merkle root built on sha256 can never be verified
 * onchain, because Ethereum hashes with keccak256. The client engine in
 * deepwood-app had the same bug. Both now use keccak256 and must stay
 * byte-identical.
 */
const keccakLike = (buf) => new Uint8Array(keccak256.arrayBuffer(buf));

function toBuf32(v) {
  const b = Buffer.alloc(32);
  let x = BigInt(v);
  for (let i = 31; i >= 0; i--) { b[i] = Number(x & 0xffn); x >>= 8n; }
  return b;
}

/**
 * Deterministically roll one hunt.
 * @param seed      season seed (hex string or bigint)
 * @param player    player address (lowercase)
 * @param huntIndex monotonically increasing per player per season
 * @param toolTier  1..4, bounds the rarity ceiling
 * @returns {{counts:number[], valueWei:bigint, total:number}}
 */
export function rollHunt(seed, player, huntIndex, toolTier) {
  const table = DROP_TABLE[toolTier];
  if (!table) throw new Error(`bad toolTier ${toolTier}`);

  // Gem count per hunt: 3..5 inclusive, derived from the same seed stream so
  // the whole result stays a deterministic function of its inputs.
  const h = keccakLike(Buffer.concat([
    toBuf32(BigInt(seed)),
    toBuf32(huntIndex),
    Buffer.from(String(player).toLowerCase()),
  ]));
  const gemCount = 3 + (h[0] % 3); // 3, 4 or 5

  const counts = [0, 0, 0, 0, 0];
  let valueWei = 0n;
  let highest = 0;

  for (let i = 0; i < gemCount; i++) {
    // Fresh entropy per gem, INCLUDING toolTier. Without the tier in the
    // stream, a tier-1 and tier-2 roll at the same index shared entropy and
    // could return the identical gem sequence -- a player swapping tools
    // would see no change at all on some hunts, which reads as a bug and
    // weakens the "better tool, better odds" signal players are paying for.
    const gb = keccakLike(Buffer.concat([h, toBuf32(toolTier), Buffer.from([i])]));
    const roll = ((gb[0] << 16) | (gb[1] << 8) | gb[2]) % 10000;

    // Walk the table; first bucket at or above `roll` wins.
    let acc = 0, picked = table.length - 1;
    for (let r = 0; r < table.length; r++) {
      acc += table[r];
      if (roll < acc) { picked = r; break; }
    }

    counts[picked] += 1;
    valueWei += PRICE[picked];
    if (picked > highest) highest = picked;
  }

  // valueWei is the TOTAL of the find; the contract compares it against the
  // player's best single find, so report the single most valuable gem too.
  // Best SINGLE gem in this find, for the leaderboard's best-find board.
  // Must be a BigInt comparison -- Math.max throws on BigInt.
  let bestSingle = 0n;
  for (let r = 0; r < counts.length; r++) {
    if (counts[r] > 0 && PRICE[r] > bestSingle) bestSingle = PRICE[r];
  }

  return { counts, valueWei, bestSingleWei: bestSingle, total: gemCount, highest };
}

/**
 * Leaf for a (player, huntIndex) pair — what the merkle tree commits to.
 *
 * The SEED MUST be inside the leaf. It was not in the first version, which
 * meant every seed produced an identical root: a "verification" pass would
 * then hold for any seed at all, and the engine could swap the seed after
 * committing and still produce a matching root. That is precisely the
 * attack the commitment exists to prevent, so the seed is bound here.
 */
export function leafFor(seed, player, huntIndex) {
  return keccakLike(Buffer.concat([
    toBuf32(BigInt(seed)),
    Buffer.from(String(player).toLowerCase()),
    toBuf32(huntIndex),
  ]));
}

function hashPair(a, b) {
  // sorted-pair merkle, standard and order-independent
  const [x, y] = Buffer.compare(a, b) <= 0 ? [a, b] : [b, a];
  return keccakLike(Buffer.concat([x, y]));
}

/** Standard binary merkle root over a leaf set. */
export function merkleRoot(leaves) {
  if (!leaves.length) return Buffer.alloc(32);
  let level = leaves.map((l) => Buffer.from(l));
  while (level.length > 1) {
    const next = [];
    for (let i = 0; i < level.length; i += 2) {
      next.push(i + 1 < level.length ? hashPair(level[i], level[i + 1]) : level[i]);
    }
    level = next;
  }
  return level[0];
}

/**
 * Commit a season: derive the merkle root over every hunt this season will
 * settle. Call once, publish on-chain, then roll.
 *
 * @param seasonSeed hex string
 * @param plan       [{player, hunts}] — how many hunts each player will make
 * @returns {{root:string, leafCount:number}}
 */
export function commitSeason(seasonSeed, plan) {
  const leaves = [];
  for (const { player, hunts } of plan) {
    for (let i = 0; i < hunts; i++) leaves.push(leafFor(seasonSeed, player, i));
  }
  const root = merkleRoot(leaves);
  // NOTE: merkleRoot() returns a Uint8Array, and a typed array IGNORES the
  // 'hex' argument to toString(). The previous `'0x' + root.toString('hex')`
  // therefore produced '0x5,126,44,...' -- comma-joined decimals, not hex.
  // That string is not a valid bytes32, so every commitment written with it
  // would have been rejected onchain. Caught by the client/engine parity
  // check in deepwood-app/src/commitment.test.mjs.
  return { root: '0x' + Buffer.from(root).toString('hex'), leafCount: leaves.length };
}

/**
 * Verify a season after the fact: re-derive every leaf from the published
 * seed and confirm the root still matches what was committed on-chain.
 */
export function verifySeason(seasonSeed, plan, committedRoot) {
  const { root } = commitSeason(seasonSeed, plan);
  return { ok: root.toLowerCase() === String(committedRoot).toLowerCase(), recomputed: root };
}

/** Expected value of one hunt at a tool tier, in wei. Useful for tuning. */
export function expectedValueWei(toolTier, gemCount = 4) {
  const table = DROP_TABLE[toolTier];
  let per = 0n;
  for (let r = 0; r < table.length; r++) {
    per += (BigInt(table[r]) * PRICE[r]) / 10_000n;
  }
  return per * BigInt(gemCount);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  console.log('DeepWood hunt engine\n');
  for (const tier of [1, 2, 3, 4]) {
    const ev = expectedValueWei(tier);
    console.log(`tier ${tier}: EV/hunt ~${Number(ev) / 1e18} ETH  table ${JSON.stringify(DROP_TABLE[tier])}`);
  }
  console.log('\nratio t4/t1 EV:', Number(expectedValueWei(4)) / Number(expectedValueWei(1)).toFixed(1) + 'x');

  const seed = '0xdeadbeef';
  console.log('\nfirst 8 rolls for 0xaaa at tier 1:');
  for (let i = 0; i < 8; i++) {
    const r = rollHunt(seed, '0xaaa', i, 1);
    const desc = r.counts.map((c, idx) => c > 0 ? `${c}x${RARITY_NAME[idx]}` : null).filter(Boolean).join(' ');
    console.log(`  #${i}: ${desc}  = ${Number(r.valueWei) / 1e18} ETH`);
  }

  const plan = [{ player: '0xaaa', hunts: 10 }, { player: '0xbbb', hunts: 5 }];
  const c = commitSeason(seed, plan);
  console.log(`\ncommit root over ${c.leafCount} leaves: ${c.root}`);
  console.log('verify:', JSON.stringify(verifySeason(seed, plan, c.root).ok));
}
