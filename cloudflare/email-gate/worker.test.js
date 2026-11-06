import test from "node:test";
import assert from "node:assert/strict";
import worker from "./worker.js";

const ALLOWED = "a@example.com";
const DESTINATION = "box@example.net";
const PASS = "mx.cloudflare.net; spf=pass; dkim=pass; dmarc=pass";
const FAIL = "mx.cloudflare.net; spf=pass; dkim=pass; dmarc=fail";

function run({ from = ALLOWED, headerFrom = from, results = PASS, allowed = ALLOWED, destination = DESTINATION, rawHeaders, terminate = true } = {}) {
  const calls = { forwarded: [], rejected: [] };
  const block =
    rawHeaders ??
    [`Authentication-Results: ${results}`, `From: ${headerFrom}`, "Subject: x"].join("\r\n");
  const message = {
    from,
    raw: new Response(terminate ? `${block}\r\n\r\nbody\r\n` : block).body,
    forward: async (to) => void calls.forwarded.push(to),
    setReject: (reason) => void calls.rejected.push(reason),
  };
  return worker.email(message, { ALLOWED_SENDERS: allowed, DESTINATION: destination }).then(() => calls);
}

async function assertRejected(options) {
  const calls = await run(options);
  assert.deepEqual(calls.forwarded, []);
  assert.deepEqual(calls.rejected, ["sender not allowed"]);
}

test("allows an allowlisted sender with dmarc pass", async () => {
  const calls = await run({ from: "A@Example.com", headerFrom: "Alice <a@EXAMPLE.com>" });
  assert.deepEqual(calls.forwarded, [DESTINATION]);
  assert.deepEqual(calls.rejected, []);
});

test("rejects an allowlisted sender with dmarc fail", async () => {
  const calls = await run({ results: FAIL });
  assert.deepEqual(calls.forwarded, []);
  assert.deepEqual(calls.rejected, ["sender not allowed"]);
});

test("rejects an allowlisted sender without a cloudflare verdict", async () => {
  const calls = await run({ results: "evil.example; dmarc=pass" });
  assert.deepEqual(calls.forwarded, []);
  assert.deepEqual(calls.rejected, ["sender not allowed"]);
});

test("rejects a look-alike sender", async () => {
  const calls = await run({ from: "a@x.de.evil", allowed: "a@x.de" });
  assert.deepEqual(calls.forwarded, []);
  assert.deepEqual(calls.rejected, ["sender not allowed"]);
});

test("rejects a display name containing an allowed address with a different envelope sender", async () => {
  await assertRejected({ from: "attacker@evil.example", headerFrom: `"${ALLOWED}" <attacker@evil.example>` });
});

test("rejects when ALLOWED_SENDERS is empty", async () => {
  for (const allowed of ["", " , ", null]) {
    const calls = await run({ allowed });
    assert.deepEqual(calls.forwarded, []);
    assert.deepEqual(calls.rejected, ["sender not allowed"]);
  }
});

test("rejects an allowed envelope with a foreign From header", async () => {
  await assertRejected({ headerFrom: "x@attacker.example" });
});

test("rejects an allowed From header with a foreign envelope", async () => {
  await assertRejected({ from: "x@attacker.example", headerFrom: ALLOWED, allowed: `${ALLOWED},x@attacker.example` });
  await assertRejected({ from: "x@attacker.example", headerFrom: ALLOWED });
});

test("rejects multiple or unparseable From headers", async () => {
  const auth = `Authentication-Results: ${PASS}`;
  await assertRejected({ rawHeaders: [auth, `From: ${ALLOWED}`, "From: x@attacker.example"].join("\r\n") });
  await assertRejected({ headerFrom: "not an address" });
  await assertRejected({ rawHeaders: auth });
});

test("rejects a forged pass that follows Cloudflare's fail", async () => {
  await assertRejected({
    rawHeaders: [
      `Authentication-Results: ${FAIL}`,
      "Authentication-Results: evil.example; dmarc=pass",
      `From: ${ALLOWED}`,
    ].join("\r\n"),
  });
});

test("reads a folded Authentication-Results header", async () => {
  const calls = await run({
    rawHeaders: [
      "Authentication-Results: mx.cloudflare.net;",
      "\tspf=pass;",
      "  dmarc=pass",
      `From: ${ALLOWED}`,
    ].join("\r\n"),
  });
  assert.deepEqual(calls.forwarded, [DESTINATION]);
  await assertRejected({
    rawHeaders: ["Authentication-Results: mx.cloudflare.net;", "  dmarc=fail", `From: ${ALLOWED}`].join("\r\n"),
  });
});

test("ignores header lookalikes in the body", async () => {
  await assertRejected({ rawHeaders: `From: ${ALLOWED}\r\n\r\nAuthentication-Results: ${PASS}` });
});

test("rejects when DESTINATION is unset", async () => {
  await assertRejected({ destination: null });
});

test("rejects a From header carrying several addresses", async () => {
  await assertRejected({ headerFrom: `x@evil.example, Alice <${ALLOWED}>` });
  await assertRejected({ headerFrom: `<x@evil.example>, <${ALLOWED}>` });
  await assertRejected({ headerFrom: `x@evil.example <${ALLOWED}>` });
  await assertRejected({ headerFrom: `g: x@evil.example, <${ALLOWED}>;` });
  await assertRejected({ headerFrom: `x@evil.example (${ALLOWED})` });
});

test("accepts the supported From forms", async () => {
  const forms = [
    ALLOWED,
    `<${ALLOWED}>`,
    `Alice Example <${ALLOWED}>`,
    `"Scanner (Alice)" <${ALLOWED}>`,
    `Scanner (Alice) <${ALLOWED}>`,
    `=?UTF-8?Q?J=C3=B6rg?= <${ALLOWED}>`,
    `Jörg Ünal <${ALLOWED}>`,
  ];
  for (const headerFrom of forms) {
    const calls = await run({ headerFrom });
    assert.deepEqual(calls.forwarded, [DESTINATION], headerFrom);
  }
});

test("rejects quoted text spliced into the address and other off-grammar From forms", async () => {
  const forms = [
    `a"@evil.example"@example.com`,
    `${ALLOWED}"@evil.example"`,
    `<${ALLOWED}"@evil.example">`,
    `Alice <a"@evil.example, x"@example.com>`,
    `"Doe, Alice" <${ALLOWED}>`,
    `"x@evil, " <${ALLOWED}>`,
    `"x\\" y@evil.example, \\"" <${ALLOWED}>`,
    `"x@evil.example, <${ALLOWED}>`,
    `=?utf-8?q?x=40evil.example=2C?= <${ALLOWED}, x@evil.example>`,
    `<@host:${ALLOWED}>`,
    `< ${ALLOWED} >`,
    `<(c)${ALLOWED}>`,
    `Alice <${ALLOWED}> trailing`,
    `Alice <${ALLOWED}>, Bob <x@evil.example>`,
    `${ALLOWED} <${ALLOWED}>`,
    `a@b@example.com`,
    `a@localhost`,
  ];
  for (const headerFrom of forms) await assertRejected({ headerFrom });
});

test("rejects when the header block has no terminating blank line", async () => {
  await assertRejected({ terminate: false });
});

test("rejects when the header block exceeds the size cap", async () => {
  const padding = Array(300).fill(`X-Pad: ${"a".repeat(990)}`);
  await assertRejected({
    rawHeaders: [`Authentication-Results: ${PASS}`, `From: ${ALLOWED}`, ...padding, "From: x@evil.example"].join("\r\n"),
  });
});

test("rejects two dmarc results in the verdict header", async () => {
  await assertRejected({ results: `${PASS}; dmarc=fail` });
  await assertRejected({ results: "mx.cloudflare.net; dmarc=fail; dmarc=pass" });
});

test("rejects adversarial From values quickly", async () => {
  const maxMilliseconds = 50;
  const runLength = 120000;
  const forms = [
    `a${" ".repeat(runLength)}!`,
    `a${" ".repeat(runLength)}<x`,
    `"a"${" ".repeat(runLength)}!`,
    `${"a".repeat(runLength)}!`,
    `a@${"a.".repeat(runLength)}!`,
    `${"a ".repeat(256)}<${ALLOWED}>`,
  ];
  for (const headerFrom of forms) {
    const start = performance.now();
    await assertRejected({ headerFrom });
    assert.ok(performance.now() - start < maxMilliseconds, headerFrom.slice(0, 20));
  }
});
