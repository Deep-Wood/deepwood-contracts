// Generate Solidity parity vectors FROM THE JS ENGINE.
//
// The point is that these numbers are produced by script/hunt-engine.mjs, not by
// the contract, so test/RollParity.t.sol is a genuine cross-implementation
// check rather than the contract agreeing with itself. If the Solidity roll ever
// drifts from the engine, every hunt the client renders will be rejected with
// ResultMismatch -- so regenerate and diff these after touching either side.
//
//   node script/gen-roll-vectors.mjs
import pkg from "js-sha3";
import { rollHunt } from "./hunt-engine.mjs";
const { keccak256 } = pkg;

// SEED must equal keccak256("deepwood-season-1-seed") on-chain. Padding the
// RAW BYTES of that string (the first attempt) is a different value entirely
// and silently desynchronised every roll.
const SEED = "0x" + keccak256("deepwood-season-1-seed");

// Exactly 40 hex digits: the engine hashes the lowercase ADDRESS STRING, and
// Solidity will not accept a shorter one as an address literal, so the two
// implementations can only agree on a well-formed address.
// Emitted to Solidity as DECIMAL. A 40-hex Solidity address literal must carry
// a valid EIP-55 checksum or be rejected, and a checksummed form would no
// longer be the exact string the engine hashed. Decimal sidesteps that while
// preserving the identical address value.
const PLAYERS = ["0xa11ce00000000000000000000000000000000000", "0xba1e1e0000000000000000000000000000000000"];

const rows = [];
for (const p of PLAYERS) {
  for (const tier of [1, 2, 3, 4]) {
    for (let i = 0; i < 3; i++) {
      const r = rollHunt(SEED, p, i, tier);
      rows.push({ p, tier, i, counts: r.counts, best: r.bestSingleWei.toString() });
    }
  }
}

const sol = rows
  .map(
    (v) =>
      `        rows.push(Roll(address(uint160(${BigInt(v.p)})), ${v.tier}, ${v.i}, ` +
      `[uint256(${v.counts[0]}), ${v.counts[1]}, ${v.counts[2]}, ${v.counts[3]}, ${v.counts[4]}], ${v.best}));`
  )
  .join("\n");

console.error(`generated ${rows.length} vectors`);
process.stdout.write(sol + "\n");
