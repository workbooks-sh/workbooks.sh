globalThis.setTimeout=function(f){Promise.resolve().then(f);return 0;};globalThis.clearTimeout=function(){};globalThis.setInterval=function(){return 0;};globalThis.clearInterval=function(){};globalThis.setImmediate=function(f){Promise.resolve().then(f);return 0;};globalThis.clearImmediate=function(){};globalThis.queueMicrotask=function(f){Promise.resolve().then(f);};
var __filename="/typescript.js"; var __dirname="/";
var global=globalThis;
var performance={now:function(){return 0;}};
var process={argv:["node"],argv0:"node",env:{},platform:"linux",arch:"wasm32",version:"v18.0.0",
  versions:{node:"18.0.0"},cwd:function(){return "/";},chdir:function(){},
  nextTick:function(f){Promise.resolve().then(f);},hrtime:function(){return [0,0];},
  stdout:{write:function(){return true;},isTTY:false},stderr:{write:function(){return true;},isTTY:false},
  on:function(){},once:function(){},exit:function(){},emitWarning:function(){}};
process.hrtime.bigint=function(){return 0n;};
var require=function(name){
  switch(name){
    case "os": return {platform:function(){return "linux";},EOL:"\n",homedir:function(){return "/";},
      tmpdir:function(){return "/tmp";},cpus:function(){return [{}];},endianness:function(){return "LE";}};
    case "fs": return {existsSync:function(){return false;},readFileSync:function(){return "";},
      writeFileSync:function(){},statSync:function(){return {};},lstatSync:function(){return {};},
      realpathSync:function(p){return p;},readdirSync:function(){return [];},
      mkdirSync:function(){},watch:function(){return {close:function(){}};}};
    case "path": return {sep:"/",delimiter:":",join:function(){return Array.prototype.join.call(arguments,"/");},
      resolve:function(){return Array.prototype.join.call(arguments,"/");},
      dirname:function(p){return p.replace(/\/[^/]*$/,"")||"/";},basename:function(p){return p.replace(/^.*\//,"");},
      extname:function(p){var m=/\.[^.]*$/.exec(p);return m?m[0]:"";},normalize:function(p){return p;},
      isAbsolute:function(p){return p.charAt(0)==="/";},relative:function(a,b){return b;}};
    default: return {};
  }
};
var module={exports:{}}; var exports=module.exports;
