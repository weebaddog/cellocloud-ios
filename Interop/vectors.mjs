// Two-way proof that the iPhone app and the website encrypt identically.
//   node Interop/vectors.mjs gen <dir>     website's crypto → <dir>/web.json (the Swift tests open it)
//   node Interop/vectors.mjs verify <dir>  website's crypto opens <dir>/swift.json (made by the Swift tests)
// web-crypto.js is a copy of cellocloud/web/crypto.js (this repo holds only the iPhone app);
// keep it in sync when that file changes.
import fs from "node:fs";
import path from "node:path";
import * as C from "./web-crypto.js";

const [mode, dir] = process.argv.slice(2);
if (!dir || !["gen", "verify"].includes(mode)) { console.error("usage: vectors.mjs gen|verify <dir>"); process.exit(2); }
fs.mkdirSync(dir, { recursive: true });

if (mode === "gen") {
  const password = "Tëst pässwörd ﬁ 10+"; // non-ASCII and a ligature: exercises the NFKC + UTF-8 path
  const salt = C.hex(C.random(16));
  const keys = await C.passwordKeys(password, salt);
  const vault = C.random(32);
  const recovery = C.random(32);
  const rk = await C.recoveryKeys(recovery);
  const fileKey = C.random(32);
  const meta = { name: "Résumé (final).pdf", type: "application/pdf", size: 12345, mtime: 1760000000000, key: C.b64(fileKey) };
  const out = {
    password, salt, authKey: keys.authKey,
    vault: C.hex(vault), wrappedVault: await C.sealB64(keys.encKey, vault),
    recovery: C.hex(recovery), recoveryText: C.recoveryText(recovery), recAuth: rk.recAuth, recWrapped: await C.sealB64(rk.encKey, vault),
    meta: await C.sealJson(await C.aesKey(vault), meta), metaName: meta.name, fileKey: C.hex(fileKey),
    chunk: C.b64(await C.seal(await C.aesKey(fileKey), new TextEncoder().encode("hello from the browser"))), chunkText: "hello from the browser",
  };
  fs.writeFileSync(path.join(dir, "web.json"), JSON.stringify(out, null, 2));
  console.log(`wrote ${path.join(dir, "web.json")}`);
} else {
  const v = JSON.parse(fs.readFileSync(path.join(dir, "swift.json"), "utf8"));
  let failed = 0;
  const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failed++; };
  const keys = await C.passwordKeys(v.password, v.salt);
  check(keys.authKey === v.authKey, "same auth key from the same password");
  check(C.hex(await C.openB64(keys.encKey, v.wrappedVault)) === v.vault, "opens the vault key the iPhone sealed with the password");
  const parsed = C.parseRecoveryText(v.recoveryText);
  check(parsed && C.hex(parsed) === v.recovery && C.recoveryText(parsed) === v.recoveryText, "same recovery key text");
  const rk = await C.recoveryKeys(parsed);
  check(rk.recAuth === v.recAuth, "same recovery auth key");
  check(C.hex(await C.openB64(rk.encKey, v.recWrapped)) === v.vault, "opens the vault key the iPhone sealed with the recovery key");
  const meta = await C.openJson(await C.aesKey(C.unhex(v.vault)), v.meta);
  check(meta.name === v.metaName && meta.type === "image/heic", "opens file details the iPhone sealed");
  const chunk = new TextDecoder().decode(await C.open(await C.aesKey(C.unhex(v.fileKey)), C.unb64(v.chunk)));
  check(chunk === v.chunkText, "opens a file piece the iPhone sealed");
  if (failed) { console.error(`${failed} FAILED`); process.exit(1); }
  console.log("ALL PASS");
}
