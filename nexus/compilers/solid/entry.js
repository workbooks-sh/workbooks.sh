// process shim (babel reads process.env / process.versions)
globalThis.process = globalThis.process || { env: {}, platform: "browser", version: "v18.0.0", versions: { node: "18.0.0" }, cwd: function(){return "/";}, argv: [], nextTick: function(f){ Promise.resolve().then(f); } };
import * as Babel from "@babel/standalone";
import presetSolid from "babel-preset-solid";
Babel.registerPreset("solid", presetSolid);
globalThis.solidTransform = function (code, fn) {
  return Babel.transform(code, { presets: ["solid"], filename: fn || "in.jsx" }).code;
};
