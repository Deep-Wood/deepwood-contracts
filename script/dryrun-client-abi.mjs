// Prove the CLIENT's calldata is accepted by the REAL contract.
//
// The previous pass wrote calldataSettleHunt() and unit-tested its shape, but
// never got it past a real EVM. This closes that: it deploys the contract to a
// local anvil, drives setup with cast, then asks the CLIENT code to encode
// previewHunt and settleHunt and sends exactly those bytes.
//
// The point is that no cast-built calldata is ever submitted for the two calls
// that matter. If the client encodes them wrong, this fails.
//
//   anvil --port 8545 &   node script/dryrun-client-abi.mjs
import { execFileSync } from "node:child_process";

const RPC = process.env.DW_RPC || "http://127.0.0.1:8545";
const SITE = process.env.DW_SITE || "/home/administrator/deepwood-site";
const REPO = process.env.DW_REPO || "/home/administrator/gem-hunter";

const KEYS = {
  "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266": "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc": "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
};
const ALICE = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const HUNTER = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC";

const sh = (cmd, cwd = REPO) => {
  try {
    return execFileSync("bash", ["-lc", cmd], { encoding: "utf8", cwd, env: process.env });
  } catch (e) {
    return { err: (e.stdout || "") + (e.stderr || "") };
  }
};
const shOut = (cmd, cwd = REPO) => {
  const r = sh(cmd, cwd);
  return typeof r === "string" ? r.trim() : "";
};
const run = (cmd, cwd = REPO) => {
  const r = sh(cmd, cwd);
  const text = typeof r === "string" ? r : r.err;
  const failed = typeof r !== "string";
  return { ok: !failed, out: text.trim(), failed };
};

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

// Deploy, then set the season up the way a real deployment would.
const dep = run(
  `forge create src/DeepWood.sol:DeepWood ${RPC === "" ? "" : `--rpc-url ${RPC}`} ` +
    `--private-key ${KEYS[ALICE.toLowerCase()]} --broadcast --json ` +
    `--constructor-args 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 ${HUNTER}`,
);
if (dep.failed) {
  console.log(dep.out.slice(0, 400));
  process.exit(1);
}
const addr = JSON.parse(dep.out).deployedTo;
console.log(`\n  deployed ${addr}\n`);

const R = `--rpc-url ${RPC}`;
const send = (sig, args, who) =>
  run(`cast send ${addr} ${sig} ${args} ${R} --private-key ${KEYS[who.toLowerCase()]} --from ${who}`);

send('"commitSeason(bytes32)(bytes32)"', "0x" + "12".repeat(32), HUNTER);
send('"commitSeed(bytes32)(bytes32)"', "0x" + "ab".repeat(32), HUNTER);
send('"claimTool(uint8)(uint8)"', "1", ALICE);

// --- the client's own encoder, driven exactly as the app would ---------
const script = `
import { calldataSettleHunt } from "${SITE}/src/wallet.js";
import { connect as chainConnect } from "${SITE}/src/chain.js";

const rpc = await chainConnect({ rpcUrl: "${RPC}", address: "${addr}", player: "${ALICE}" });

// 1. The reader the game uses for its preview.
const preview = await rpc.previewHunt("${ALICE}", 1);
const idx0 = await rpc.huntIndexOf("${ALICE}");
const season = await rpc.current();

// 2. The writer, using ONLY what the reader returned.
const settle = calldataSettleHunt("${ALICE}", 1, preview.counts, preview.bestSingleWei);

console.log(JSON.stringify({
  counts: preview.counts.map(String),
  best: preview.bestSingleWei.toString(),
  huntIndex: String(idx0),
  seedCommitted: season.seedCommitted,
  seed: season.seed,
  settle,
}));
`;
const fs = await import("node:fs");
const tmp = `${SITE}/_abi_probe.mjs`;
fs.writeFileSync(tmp, script);
let out = "";
try {
  out = shOut(`node ${tmp}`, SITE);
} finally {
  fs.rmSync(tmp, { force: true });
}
if (!out.startsWith("{")) {
  console.log("  client probe failed:\n" + out.slice(0, 600));
  process.exit(1);
}
const p = JSON.parse(out);

console.log(`  client previewHunt -> counts=[${p.counts}] best=${p.best}`);
console.log(`  client huntIndexOf -> ${p.huntIndex}, seedCommitted=${p.seedCommitted}\n`);

check("client decodes previewHunt into 5 rarity counts", p.counts.length === 5, `[${p.counts}]`);
check("client decodes a non-zero bestSingleWei", BigInt(p.best) > 0n, p.best);
check("client reads the new Season seed word", p.seedCommitted === true, p.seed.slice(0, 18) + "...");
check("client reads huntIndex before settling", p.huntIndex === "0", p.huntIndex);

// Cross-check the decoded preview against the chain, independently.
const raw = shOut(`cast call ${addr} "previewHunt(address,uint8)" ${ALICE} 1 ${R}`);
const words = raw.replace(/^0x/, "").match(/.{64}/g).map((w) => BigInt("0x" + w));
const decodedOk = words.slice(0, 5).every((w, i) => w === BigInt(p.counts[i])) && words[5] === BigInt(p.best);
check("client's decoded preview equals the raw chain words", decodedOk, `chain=[${words.slice(0, 5)}]`);

// Now send the CLIENT's bytes. Nothing here is cast-encoded.
const sent = run(
  `cast send ${addr} ${p.settle} ${R} --private-key ${KEYS[ALICE.toLowerCase()]} --from ${ALICE}`,
);
check(
  "client-encoded settleHunt is ACCEPTED by the contract",
  !/revert|error/i.test(sent.out) && /transactionHash|status|blockNumber/i.test(sent.out),
  sent.out.slice(0, 90).replace(/\s+/g, " "),
);

const after = BigInt(shOut(`cast call ${addr} "huntIndexOf(address)" ${ALICE} ${R}`));
check(
  "hunt index advanced, so the settlement really applied",
  after !== BigInt(p.huntIndex),
  `${p.huntIndex} -> ${after}`,
);

// A wrong result must still be refused -- proves we did not accidentally
// succeed because the contract was not checking.
const forged = run(
  `cast send ${addr} ${p.settle.replace(/0{40}$/, "0".repeat(39) + "1")} ${R} ` +
    `--private-key ${KEYS[ALICE.toLowerCase()]} --from ${ALICE}`,
);
check(
  "a doctored settleHunt is still rejected",
  /revert|ResultMismatch/i.test(forged.out),
  forged.out.slice(0, 90).replace(/\s+/g, " "),
);

console.log(`\n${fail === 0 ? "CLIENT ABI PASSED" : fail + " CHECK(S) FAILED"} — ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);