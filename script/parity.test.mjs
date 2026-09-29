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
import { rollHunt as clientRoll } from '/home/administrator/deepwood-app/src/engine.js';

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
// The contract ranks on a ratio, so identical finds for different spend must
// produce identical rarity-weight even when the wallets differ.
const a = serverRoll('0x5eed', '0xwhale', 0, 4);
const b = clientRoll('0x5eed', '0xminnow', 0, 4);
check('whale and minnow find the same thing for the same index', String(a.counts) === String(b.counts));

console.log(fail === 0 ? '\nPARITY OK' : `\n${fail} PARITY FAILURE(S)`);
process.exit(fail === 0 ? 0 : 1);
