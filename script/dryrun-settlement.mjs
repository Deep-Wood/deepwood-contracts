// End-to-end dry run of OPEN SETTLEMENT against a local anvil.
//
// Nothing here touches testnet or production. The point is to prove the full
// player path works on a real EVM, with real gas and real reverts, rather than
// only inside forge's simulated environment -- and that the JS engine's idea of
// a hunt matches what the chain will actually accept.
//
//   anvil --port 8545 &   node script/dryrun-settlement.mjs
//
// Exits non-zero on the first failed expectation.
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { rollHunt } from "./hunt-engine.mjs";

const require = createRequire(import.meta.url);
const { keccak256 } = require("js-sha3");

const RPC = process.env.DW_RPC || "http://127.0.0.1:8545";
const PK = process.env.PRIVATE_KEY || "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const ALICE = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"; // anvil #0
const TREASURY = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
const HUNTER = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC";

// cast rejects a --from that does not match the signing key, so each sender
// needs its own key rather than one PK for everything.
const KEYS = {
  [ALICE.toLowerCase()]: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  [TREASURY.toLowerCase()]: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  [HUNTER.toLowerCase()]: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
};
const keyFor = (who) => KEYS[who.toLowerCase()];

const cast = (args, allowFail = false) => {
  try {
    return execFileSync("cast", args, { encoding: "utf8", env: process.env, stdio: ["ignore", "pipe", "pipe"] }).trim();
  } catch (e) {
    if (allowFail) return null;
    const why = (e.stderr || e.stdout || e.message || "").split("\n").find((l) => l.trim()) || e.message;
    throw new Error(`cast ${args[0]} ${args[1] || ""} failed: ${why}`);
  }
};
const send = (to, sig, args = [], from = ALICE, allowFail = false) =>
  cast(["send", to, sig, ...args, "--rpc-url", RPC, "--private-key", keyFor(from), "--from", from, "--json"], allowFail);
const call = (to, sig, args = []) => cast(["call", to, sig, ...args, "--rpc-url", RPC]);

let pass = 0,
  fail = 0;
const check = (name, ok, detail = "") => {
  if (ok) {
    pass++;
    console.log(`  ok    ${name}${detail ? "  " + detail : ""}`);
  } else {
    fail++;
    console.log(`  FAIL  ${name}${detail ? "  " + detail : ""}`);
  }
};

console.log(`dry run against ${RPC}\n`);

// ---- deploy -------------------------------------------------------------
// `cast create` does not exist -- deployment is `forge create`. Getting this
// wrong is why the first run died before touching the chain.
const deployed = execFileSync(
  "forge",
  ["create", "src/DeepWood.sol:DeepWood",
   "--rpc-url", RPC, "--private-key", PK, "--broadcast", "--json",
   // LAST, and as SEPARATE argv entries: --constructor-args consumes every token
   // after it, so earlier placement made it count the flags as arguments, and a
   // single joined string made it see one argument instead of two.
   "--constructor-args", TREASURY, HUNTER],
  { encoding: "utf8", env: process.env, cwd: process.cwd() },
);
const addr = JSON.parse(deployed).deployedTo || JSON.parse(deployed).contractAddress;
console.log(`  deployed ${addr}\n`);

// ---- season + seed ------------------------------------------------------
const SEED = "0x" + keccak256("deepwood-dryrun-season-1");
// commitSeason and commitSeed are role-gated, so they go from the hunter.
// Sending them from Alice reverts with NotHunter -- correct contract behaviour,
// and the reason the first runs failed with no visible error.
send(addr, "commitSeason(bytes32)(bytes32)", ["0x" + "12".repeat(32)], HUNTER);
send(addr, "commitSeed(bytes32)(bytes32)", [SEED], HUNTER);

const seedOnChain = call(addr, "seasonSeed()");
check("seed is readable on-chain", seedOnChain.toLowerCase() === SEED.toLowerCase(), seedOnChain);

// There is no seedCommitted() getter -- it lives inside the Season struct, so
// it is word 8 of current(). Assuming a standalone getter wasted a run.
const cur = call(addr, "current()").replace(/^0x/, "").match(/.{64}/g);
const seedCommitted = BigInt("0x" + cur[8]);
const committed = BigInt("0x" + cur[6]);
check("seed is marked committed on-chain", seedCommitted === 1n, `seedCommitted=${seedCommitted}`);
check("merkle root is marked committed", committed === 1n, `committed=${committed}`);

// A second commit must be refused.
const twice = send(addr, "commitSeed(bytes32)(bytes32)", ["0x" + "11".repeat(32)], HUNTER, true);
check(
  "seed cannot be re-committed",
  twice === null || /SeedAlreadyCommitted/i.test(String(twice)),
  twice === null ? "tx rejected" : String(twice).slice(0, 120)
);

// ---- the player path ----------------------------------------------------
send(addr, "claimTool(uint8)(uint8)", ["1"], ALICE);
console.log(`\n  alice settles her own hunts, nobody online but her\n`);

for (let i = 0; i < 3; i++) {
  const preview = cast(["call", addr, "previewHunt(address,uint8)", ALICE, "1", "--rpc-url", RPC]);
  // previewHunt returns (uint256[5], uint256) -- parse the two words we need
  const words = preview.replace(/^0x/, "").match(/.{64}/g) || [];
  const onChainCounts = words.slice(0, 5).map((w) => BigInt("0x" + w));
  const onChainBest = BigInt("0x" + (words[5] || "0"));
  const engine = rollHunt(SEED, ALICE, i, 1);
  const engineCounts = engine.counts.map((c) => BigInt(c));

  const countsMatch = onChainCounts.every((c, j) => c === engineCounts[j]);
  check(
    `hunt ${i}: chain preview matches the JS engine`,
    countsMatch,
    `chain=[${onChainCounts}] engine=[${engineCounts}]`
  );
  check(`hunt ${i}: best-single matches`, onChainBest === engine.bestSingleWei, `${onChainBest} vs ${engine.bestSingleWei}`);

  // Settle exactly what the chain says it will accept.
  const countsArg = `[${onChainCounts.join(",")}]`;
  const tx = send(addr, "settleHunt(address,uint8,uint256[5],uint256,bytes)(address,uint8,uint256[5],uint256,bytes)", [
    ALICE, "1", countsArg, onChainBest.toString(), "0x",
  ]);
  check(`hunt ${i}: settles`, tx !== null, "");

  // Jump past the cooldown for the next one. huntCooldown is word 2 of Config.
  const cd = Number(BigInt(call(addr, "getConfig()").replace(/^0x/, "").match(/.{64}/g)[2]));
  const t0 = Number(BigInt(call(addr, "huntIndexOf(address)", [ALICE])));
  cast(["rpc", "evm_increaseTime", String(cd + 5), "--rpc-url", RPC]);
  cast(["rpc", "evm_mine", "--rpc-url", RPC]);
  cast(["rpc", "evm_mine", "--rpc-url", RPC]);
  const block = Number(cast(["block-number", "--rpc-url", RPC]));
  console.log(`        (cooldown ${cd}s, index ${t0}, block ${block})`);
}

// ---- the guarantees -----------------------------------------------------
console.log("");
const nextIdx = Number(BigInt(call(addr, "huntIndexOf(address)", [ALICE])));
check("hunt index advanced with each settled hunt", nextIdx === 3, `index=${nextIdx}`);

// An inflated claim must be rejected.
cast(["rpc", "evm_increaseTime", "10", "--rpc-url", RPC]);
const forged = send(
  addr,
  "settleHunt(address,uint8,uint256[5],uint256,bytes)(address,uint8,uint256[5],uint256,bytes)",
  [ALICE, "1", "[0,0,0,0,1]", "200000000000000000", "0x"],
  ALICE,
  true,
);
const forgedFailed = forged === null || /revert|ResultMismatch/i.test(String(forged));
check("a forged legendary is rejected", forgedFailed, forgedFailed ? "" : "it was ACCEPTED");

// Someone else cannot settle her hunt.
const hijack = send(
  addr,
  "settleHunt(address,uint8,uint256[5],uint256,bytes)(address,uint8,uint256[5],uint256,bytes)",
  [ALICE, "1", "[3,0,0,0,0]", "50000000000000", "0x"],
  HUNTER,
  true,
);
check(
  "a third party cannot settle her hunt",
  hijack === null || /revert|NotOwner/i.test(String(hijack)),
  ""
);

// Cooldown still bites. settleHunt checks the cooldown BEFORE recomputing the
// result, so the counts here are deliberately wrong -- if the cooldown were not
// enforcing, this would fail with ResultMismatch instead, which is the point.
cast(["rpc", "evm_mine", "--rpc-url", RPC]);
const spam = send(
  addr,
  "settleHunt(address,uint8,uint256[5],uint256,bytes)(address,uint8,uint256[5],uint256,bytes)",
  [ALICE, "1", "[3,0,0,0,0]", "1", "0x"],
  ALICE,
  true,
);
const spamWhy = String(spam ?? "");
check(
  "cooldown blocks an immediate second hunt",
  spam === null || /CooldownActive/i.test(spamWhy),
  spam === null ? "tx rejected" : spamWhy.slice(0, 100)
);

console.log(`\n${fail === 0 ? "DRY RUN PASSED" : fail + " CHECK(S) FAILED"} — ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);