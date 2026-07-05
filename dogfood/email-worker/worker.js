// Cloudflare Email Worker — the INBOUND half of agent email.
//
// Mail to agents.workbooks.sh is routed here by the Email Routing catch-all
// (Nexus.Cloudflare.set_email_catch_all/2 → this worker). We parse the MIME at the edge and POST clean
// JSON to the Nexus ingress (POST /api/email/inbound), which stores it in the recipient tenant's inbox
// and emits `email.received` (waking the agent). Dependency-free on purpose — no npm, no build, no JSON
// sidecar: handles single-part text, multipart/alternative, and quoted-printable + base64 encodings.

function headerVal(block, name) {
  const m = new RegExp("^" + name + ":\\s*(.*(?:\\r?\\n\\s+.*)*)", "im").exec(block);
  return m ? m[1].replace(/\r?\n\s+/g, " ").trim() : "";
}

function splitHeaderBody(chunk) {
  const i = chunk.search(/\r?\n\r?\n/);
  if (i < 0) return [chunk, ""];
  const nl = chunk.slice(i).match(/^\r?\n\r?\n/)[0].length;
  return [chunk.slice(0, i), chunk.slice(i + nl)];
}

function decodePart(body, encoding) {
  const enc = (encoding || "").toLowerCase();
  if (enc === "base64") {
    try { return decodeURIComponent(escape(atob(body.replace(/\s+/g, "")))); } catch (e) { return body; }
  }
  if (enc === "quoted-printable") {
    return body.replace(/=\r?\n/g, "").replace(/=([0-9A-Fa-f]{2})/g, (_, h) => String.fromCharCode(parseInt(h, 16)));
  }
  return body;
}

function extractText(raw) {
  const [head, body] = splitHeaderBody(raw);
  const ctype = headerVal(head, "content-type").toLowerCase();
  if (ctype.startsWith("multipart/")) {
    const b = /boundary="?([^";\r\n]+)"?/i.exec(ctype);
    if (b) {
      for (const part of body.split("--" + b[1])) {
        const [ph, pb] = splitHeaderBody(part);
        if (/content-type:\s*text\/plain/i.test(ph)) {
          return decodePart(pb, headerVal(ph, "content-transfer-encoding")).trim();
        }
      }
    }
  }
  return decodePart(body, headerVal(head, "content-transfer-encoding")).trim();
}

export default {
  async email(message, env) {
    const raw = await new Response(message.raw).text();
    const [head] = splitHeaderBody(raw);

    const payload = {
      from: message.from,
      to: message.to,
      subject: headerVal(head, "subject"),
      text: extractText(raw),
      html: "",
      message_id: headerVal(head, "message-id"),
      in_reply_to: headerVal(head, "in-reply-to"),
      references: headerVal(head, "references"),
    };

    const res = await fetch(env.NEXUS_INGRESS_URL, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-email-ingress-secret": env.EMAIL_INGRESS_SECRET,
      },
      body: JSON.stringify(payload),
    });

    // Reject on ingress failure so mail is bounced (sender + CF retry), never silently dropped.
    if (!res.ok) message.setReject("nexus email ingress unavailable (" + res.status + ")");
  },
};
