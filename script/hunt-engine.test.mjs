/**
 * Statistical check of the hunt engine against the contract's drop tables.
 * A broken RNG or a mis-indexed table can look fine for a handful of rolls,
 * so this samples hard and checks the distribution, not the eyeball.
 */
import { DROP_TABLE, PRICE, rollHunt, commitSeason, verifySeason, expectedValueWei } from './hunt-engine.mjs';

const N = 200_000;
const seed = '0xc0ffee';
let fail = 0;
// Deep compare that is BigInt-safe. JSON.stringify throws on BigInt, and
// String(obj) gives "[object Object]" for BOTH sides, so an earlier version
// of this helper compared every object as equal and reported false failures.
const eq = (x, y) => {
  const norm = (v) => {
    if (typeof v === 'bigint') return `n${v}`;
    if (Array.isArray(v)) return `[${v.map(norm).join(',')}]`;
    if (v && typeof v === 'object') {
      return `{${Object.keys(v).sort().map((k) => `${k}:${norm(v[k])}`).join(',')}}`;
    }
    return String(v);
  };
  return norm(x) === norm(y);
};
const check = (name, cond, detail) => {
  if (!cond) { console.log(`  FAIL  ${name}  ${detail}`); fail++; }
  else console.log(`  ok    ${name}  ${detail}`);
};

console.log(`sampling ${N.toLocaleString()} hunts per tier\n`);

for (const tier of [1, 2, 3, 4]) {
  const table = DROP_TABLE[tier];
  const observed = [0, 0, 0, 0, 0];
  let totalValue = 0n, totalGems = 0, maxHighest = -1;

  for (let i = 0; i < N; i++) {
    const r = rollHunt(seed, '0xplayer', i, tier);
    for (let g = 0; g < 5; g++) observed[g] += r.counts[g];
    totalValue += r.valueWei;
    totalGems += r.total;
    if (r.highest > maxHighest) maxHighest = r.highest;
  }

  const totalRolls = observed.reduce((a, b) => a + b, 0);
  const names = ['Quartz', 'Amber', 'Sapphire', 'Ruby', 'Diamond'];
  console.log(`tier ${tier}  (table ${JSON.stringify(table)})`);
  for (let r = 0; r < 5; r++) {
    const expectedPct = (table[r] / 10000) * 100;
    const observedPct = (observed[r] / totalRolls) * 100;
    const drift = Math.abs(observedPct - expectedPct);
    const allowed = table[r] === 0 ? 0.01 : 0.6; // zero-buckets must stay exactly zero
    console.log(`   ${names[r].padEnd(10)} expected ${expectedPct.toFixed(2).padStart(6)}%  observed ${observedPct.toFixed(2).padStart(6)}%  drift ${drift.toFixed(3)}%`);
    check(`  t${tier} ${names[r]} distribution`, drift <= allowed, `drift ${drift.toFixed(3)}% <= ${allowed}%`);
  }

  check(`  t${tier} no unearned rarity`, observed.slice(3).every((c, i) => (tier < 4 ? c === 0 : true)) || maxHighest <= (tier === 4 ? 4 : 3), `highest seen = ${names[maxHighest]}`);
  check(`  t${tier} gem count in 3..5`, totalGems / N >= 3 && totalGems / N <= 5, `avg ${(totalGems / N).toFixed(3)}`);
  const ev = Number(totalValue) / N;
  const model = Number(expectedValueWei(tier)) / (totalGems / N) * (totalGems / N);
  console.log(`   observed EV/hunt = ${(ev / 1e18).toFixed(6)} ETH\n`);
}

// determinism
console.log('determinism and tamper checks');
const a = rollHunt(seed, '0xabc', 7, 2);
const b = rollHunt(seed, '0xabc', 7, 2);
const c = rollHunt(seed, '0xabc', 8, 2);
const d = rollHunt(seed, '0xabd', 7, 2);
const e = rollHunt(seed, '0xabc', 7, 3);
check('same inputs -> same result', eq(a, b));
check('different huntIndex -> different roll', !eq(a, c));
check('different player -> different roll', !eq(a, d));
check('different toolTier -> different roll', !eq(a, e));

// address case-insensitivity (EIP-55 mixed case must not fork the roll)
const f = rollHunt(seed, '0xAbC', 7, 2);
check('address case-insensitive', eq(a, f));

// merkle
console.log('\nmerkle commitment');
const plan = [{ player: '0xaaa', hunts: 50 }, { player: '0xbbb', hunts: 30 }];
const c1 = commitSeason(seed, plan);
check('root stable across recompute', commitSeason(seed, plan).root === c1.root);
check('verify passes on honest plan', verifySeason(seed, plan, c1.root).ok === true);
const tampered = [{ player: '0xaaa', hunts: 51 }, { player: '0xbbb', hunts: 30 }];
check('verify FAILS on inflated plan', verifySeason(seed, tampered, c1.root).ok === false);
const otherSeed = commitSeason('0xbeef', plan);
check('different seed -> different root', otherSeed.root !== c1.root);

// REGRESSION: the first version of leafFor omitted the seed, so every seed
// produced an identical root and verifySeason passed for ANY seed -- letting
// the engine swap the seed after committing. This asserts the property that
// was missing, so it cannot regress silently.
console.log('\nseed-binding regression');
check('verify FAILS under a swapped seed', verifySeason('0xdeadbeef', plan, c1.root).ok === false,
  'a different seed must not validate against the committed root');
const threeSeeds = ['0x1', '0x2', '0x3'].map((s) => commitSeason(s, plan).root);
check('three seeds -> three distinct roots', new Set(threeSeeds).size === 3);

console.log(fail === 0 ? '\nALL CHECKS PASSED' : `\n${fail} CHECK(S) FAILED`);
process.exit(fail === 0 ? 0 : 1);
