// CelloCloud's end-to-end encryption, all in the browser (WebCrypto).
//
//   password ──PBKDF2-SHA256, 600k rounds, per-user salt──▶ 64 bytes
//     ├─ first 32: password key (encrypts the vault key; never leaves this device)
//     └─ last 32:  auth key (sent to sign in; the server only keeps a scrypt hash of it)
//   vault key:     32 random bytes, made at sign-up; encrypts every file's details + key
//   recovery key:  32 random bytes shown once at sign-up; HKDF → its own encrypt + auth keys,
//                  so "forgot password" can unlock the vault key without the password
//   each file:     its own random 32-byte key; every 4 MB piece is AES-256-GCM sealed
//
// Sealed format everywhere: 12-byte random nonce ‖ ciphertext ‖ 16-byte tag.

const enc = new TextEncoder();
const dec = new TextDecoder();
const subtle = crypto.subtle;
const PBKDF2_ROUNDS = 600_000;
export const CHUNK_SIZE = 4 * 1024 * 1024;

export const random = (n) => crypto.getRandomValues(new Uint8Array(n));
export const hex = (buf) => Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, "0")).join("");
export const unhex = (h) => Uint8Array.from(h.match(/../g), (x) => parseInt(x, 16));

export function b64(buf) {
  const a = new Uint8Array(buf);
  let s = "";
  for (let i = 0; i < a.length; i += 0x8000) s += String.fromCharCode(...a.subarray(i, i + 0x8000));
  return btoa(s);
}
export const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

/** The two keys made from a password (see the top of this file). */
export async function passwordKeys(password, saltHex) {
  const base = await subtle.importKey("raw", enc.encode(password.normalize("NFKC")), "PBKDF2", false, ["deriveBits"]);
  const bits = new Uint8Array(await subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt: unhex(saltHex), iterations: PBKDF2_ROUNDS }, base, 512));
  const encKey = await subtle.importKey("raw", bits.slice(0, 32), "AES-GCM", false, ["encrypt", "decrypt"]);
  return { encKey, authKey: hex(bits.slice(32)) };
}

/** The two keys made from the recovery key. */
export async function recoveryKeys(recovery) {
  const base = await subtle.importKey("raw", recovery, "HKDF", false, ["deriveBits"]);
  const derive = async (info) => new Uint8Array(await subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(32), info: enc.encode(info) }, base, 256));
  const encKey = await subtle.importKey("raw", await derive("cellocloud recovery encrypt"), "AES-GCM", false, ["encrypt", "decrypt"]);
  return { encKey, recAuth: hex(await derive("cellocloud recovery auth")) };
}

export async function seal(key, data) {
  const iv = random(12);
  const ct = new Uint8Array(await subtle.encrypt({ name: "AES-GCM", iv }, key, data));
  const out = new Uint8Array(12 + ct.length);
  out.set(iv);
  out.set(ct, 12);
  return out;
}

export async function open(key, sealed) {
  const s = new Uint8Array(sealed);
  return new Uint8Array(await subtle.decrypt({ name: "AES-GCM", iv: s.subarray(0, 12) }, key, s.subarray(12)));
}

/** A raw 32-byte key as a usable AES key. Not extractable: the browser won't hand the bytes back out. */
export const aesKey = (raw) => subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);

export const sealB64 = async (key, raw) => b64(await seal(key, raw));
export const openB64 = async (key, s) => open(key, unb64(s));
export const sealJson = async (key, obj) => b64(await seal(key, enc.encode(JSON.stringify(obj))));
export const openJson = async (key, s) => JSON.parse(dec.decode(await open(key, unb64(s))));

// ---- recovery key as text (Crockford base32, groups of 4; ambiguous letters accepted) ----
const B32 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

export function recoveryText(bytes) {
  let bits = 0, value = 0, out = "";
  for (const b of bytes) {
    value = (value << 8) | b;
    bits += 8;
    while (bits >= 5) { out += B32[(value >>> (bits - 5)) & 31]; bits -= 5; }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out.match(/.{1,4}/g).join("-");
}

export function parseRecoveryText(text) {
  const clean = text.toUpperCase().replace(/[^0-9A-Z]/g, "").replace(/O/g, "0").replace(/[IL]/g, "1");
  let bits = 0, value = 0;
  const out = [];
  for (const ch of clean) {
    const v = B32.indexOf(ch);
    if (v < 0) return null;
    value = (value << 5) | v;
    bits += 5;
    if (bits >= 8) { out.push((value >>> (bits - 8)) & 255); bits -= 8; }
  }
  return out.length === 32 ? new Uint8Array(out) : null;
}
