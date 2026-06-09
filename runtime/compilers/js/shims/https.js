/* Node 'https' shim (wb-e1x.4 / JD.4) — same host-brokered GET surface as 'http' (Javy.Net.get
 * follows the URL scheme, so https URLs work through the same host fetch). */
"use strict";
module.exports = require("./http");
