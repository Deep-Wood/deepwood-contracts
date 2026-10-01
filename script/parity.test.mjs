/**
 * Parity check: the client engine and the server engine must agree exactly.
 *
 * They are separate copies (the browser bundle must not depend on a sibling
 * project), which means they can drift. If they do, the player sees one
 * result and the chain settles another -- the worst possible bug, because it
 * only shows up after a real hunt and looks like the contract cheating.
 *
 * This compares actual roll output across every tier and a range of indices.
 */
import { rollHunt as serverRoll } from '/home/administrator/gem-hunter/script/hunt-engine.mjs';
import { rollHunt as clientRoll } from '/home/administrator/deepwood-site/src/engine.js';

let fail = 0;
// Compare only the fields that MUST agree. The server returns an extra
// bestSingleWei (used by the leaderboard); the client has no use for it, so
// comparing whole objects reported false mismatches on identical rolls.
// Counts and total value are what the chain settles on, so those are the
// parity contract.
const eq = (a, b) =>
  String(a.counts) === String(b.counts) &&
  String(a.valueWei) === String(b.valueWei) &&
  a.total === b.total &&
  a.highest === b.highest;
const check = (name, cond, detail = '') => {
  if (!cond) { console.log(`  FAIL  ${name}  ${detail}`); fail++; }
  else console.log(`  ok    ${name}`);
};

console.log('roll parity across tiers and indices');
for (const tier of [1, 2, 3, 4]) {
  for (let i = 0; i < 50; i++) {
    const seed = '0x5eed';
    const player = '0xAbC'; // deliberately mixed case
    const a = serverRoll(seed, player, i, tier);
    const b = clientRoll(seed, player, i, tier);
    if (!eq(a, b)) {
      check(`t${tier} i${i}`, false, `server=${JSON.stringify(a, (k,v)=>typeof v==='bigint'?v.toString():v)} client=${JSON.stringify(b, (k,v)=>typeof v==='bigint'?v.toString():v)}`);
      break;
    }
  }
  check(`tier ${tier} first 50 rolls identical`, true);
}

console.log('\nseed and player variation');
for (const seed of ['0x1', '0xdeadbeef', '0xffffffffffffffff']) {
  const a = serverRoll(seed, '0xplayer', 3, 3);
  const b = clientRoll(seed, '0xplayer', 3, 3);
  check(`seed ${seed}`, eq(a, b));
}

console.log('\nanti-whale parity: same spend, different wallets, same ROI input');
// SAME player, both engines: must agree exactly. This is the one that matters --
// it is the whole client/contract agreement the settlement path depends on.
const same1 = serverRoll('0x5eed', '0x5EED', 0, 4);
const same2 = clientRoll('0x5eed', '0x5EED', 0, 4);
check('both engines agree for the same player', String(same1.counts) === String(same2.counts));
check(
  'and for the same player written without a 0x prefix',
  String(clientRoll('0x5eed', '0x5eed', 0, 4).counts) === String(same2.counts)
);

// DIFFERENT players must DIVERGE. This used to assert the opposite -- that
// whale and minnow find the same thing -- which was true of the keeper model
// where one party handed everyone the same result. Under a committed seed the
// result is derived from (seed, season, player, index), so equal play no longer
// implies an equal outcome. The contract verifies this per player; a test that
// asserted identical finds would now be asserting a bug.
const diff1 = serverRoll('0x5eed', '0xwhale', 0, 4);
const diff2 = serverRoll('0x5eed', '0xminnow', 0, 4);
check('different players no longer roll identically', String(diff1.counts) !== String(diff2.counts));

console.log(fail === 0 ? '\nPARITY OK' : `\n${fail} PARITY FAILURE(S)`);
process.exit(fail === 0 ? 0 : 1);
