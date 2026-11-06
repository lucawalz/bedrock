const REJECT_REASON = "sender not allowed";
const VERDICT_AUTHSERV_ID = "mx.cloudflare.net";
const MAX_HEADER_BYTES = 256 * 1024;
const HEADER_END = /\r?\n\r?\n/;
const MAX_FROM_LENGTH = 512;

function allowedSenders(raw) {
  return new Set(
    String(raw ?? "")
      .split(",")
      .map((entry) => entry.trim().toLowerCase())
      .filter((entry) => entry.includes("@")),
  );
}

async function readHeaderBlock(raw) {
  const [head] = raw.tee();
  const reader = head.getReader();
  const decoder = new TextDecoder();
  let text = "";
  try {
    while (text.length < MAX_HEADER_BYTES) {
      const { done, value } = await reader.read();
      if (done) return null;
      text += decoder.decode(value, { stream: true });
      const end = text.search(HEADER_END);
      if (end !== -1) return text.slice(0, end);
    }
    return null;
  } finally {
    reader.cancel().catch(() => {});
  }
}

function parseHeaders(block) {
  const unfolded = block.replace(/\r?\n[ \t]+/g, " ");
  return unfolded
    .split(/\r?\n/)
    .map((line) => {
      const colon = line.indexOf(":");
      return colon > 0 ? [line.slice(0, colon).trim().toLowerCase(), line.slice(colon + 1).trim()] : null;
    })
    .filter(Boolean);
}

const ADDR_SPEC = "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+";
const UNQUOTED_NAME = "[\\p{L}\\p{N} .'()=?_-]+";
const QUOTED_NAME = '"[^"\\\\<>,;:@]*"';
const BARE_ADDRESS = new RegExp(`^(${ADDR_SPEC})$`);
const ANGLE_ADDRESS = new RegExp(`^(?:${UNQUOTED_NAME}|${QUOTED_NAME} *)?<(${ADDR_SPEC})>$`, "u");

function fromAddress(headers) {
  const froms = headers.filter(([name]) => name === "from");
  if (froms.length !== 1) return null;
  const value = froms[0][1];
  if (value.length > MAX_FROM_LENGTH) return null;
  const match = value.match(BARE_ADDRESS) ?? value.match(ANGLE_ADDRESS);
  return match ? match[1].toLowerCase() : null;
}

function dmarcPassed(headers) {
  const first = headers.find(([name]) => name === "authentication-results");
  if (!first) return false;
  const [authservId, ...results] = first[1].split(";").map((part) => part.trim().toLowerCase());
  const verdicts = results.filter((part) => part.startsWith("dmarc="));
  return authservId === VERDICT_AUTHSERV_ID && verdicts.length === 1 && /^dmarc=pass(\s|$)/.test(verdicts[0]);
}

export default {
  async email(message, env) {
    const allowed = allowedSenders(env.ALLOWED_SENDERS);
    if (!env.DESTINATION) {
      message.setReject(REJECT_REASON);
      return;
    }
    const envelope = String(message.from).trim().toLowerCase();
    if (!allowed.has(envelope)) {
      message.setReject(REJECT_REASON);
      return;
    }
    const block = await readHeaderBlock(message.raw);
    if (block === null) {
      message.setReject(REJECT_REASON);
      return;
    }
    const headers = parseHeaders(block);
    const from = fromAddress(headers);
    if (from !== envelope || !dmarcPassed(headers)) {
      message.setReject(REJECT_REASON);
      return;
    }
    await message.forward(env.DESTINATION);
  },
};
