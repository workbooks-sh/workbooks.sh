// node:net + node:dns — TCP client sockets over the host bridge (__host net_*) → Nexus.Washy.HostNet →
// :gen_tcp. Streaming inbound bytes arrive via an event CHANNEL: socket.connect opens a __wb_open_channel,
// passes its id to net_open; the host re-enters wb_event per {:tcp,...} delivery, emitting 'data'/'close'.
// net.Socket is an EventEmitter (in-scope from 20_events.js). Client side first; servers (listen/accept)
// are a follow-up (need the host listen-socket seam, shared with WASIX §3).
function __net_inherit(C){C.prototype=Object.create(EventEmitter.prototype);C.prototype.constructor=C;}

function Socket(){EventEmitter.call(this);this._id=null;this._ch=null;this.connecting=false;this.destroyed=false;this.writable=false;this.readable=false;}
__net_inherit(Socket);
Socket.prototype.connect=function(port,host,cb){var self=this;
  if(typeof port==='object'){var o=port;cb=host;host=o.host;port=o.port;}
  if(typeof host==='function'){cb=host;host=undefined;}
  host=host||'127.0.0.1';
  if(cb)this.once('connect',cb);
  this._ch=__wb_open_channel(function(ev,val){self.__onEvent(ev,val);});
  var r=__host('net_open',[String(host),port|0,this._ch]);
  if(!r||!r.ok){this.__err((r&&r.err)||'ECONNREFUSED');return this;}
  this._id=r.id;this.writable=true;this.readable=true;
  queueMicrotask(function(){self.emit('connect');});
  return this;};
Socket.prototype.__onEvent=function(ev,val){
  if(ev==='data'){this.emit('data',Buffer.from(val,'base64'));}
  else if(ev==='close'){this.readable=false;this.writable=false;this.emit('end');this.emit('close',false);if(this._ch)__wb_close_channel(this._ch);}
  else if(ev==='error'){this.__err(val);}};
Socket.prototype.write=function(data,enc,cb){
  if(typeof enc==='function'){cb=enc;enc=undefined;}
  var buf=Buffer.isBuffer(data)?data:Buffer.from(String(data),(typeof enc==='string'?enc:'utf8'));
  var r=__host('net_write',[this._id,buf.toString('base64')]);
  if(cb)queueMicrotask(cb);
  return !!(r&&r.ok);};
Socket.prototype.end=function(data,enc){if(data!=null)this.write(data,enc);if(this._id!=null){__host('net_close',[this._id]);this.writable=false;}return this;};
Socket.prototype.destroy=function(){if(this._id!=null)__host('net_close',[this._id]);this.destroyed=true;this.writable=false;this.readable=false;if(this._ch)__wb_close_channel(this._ch);return this;};
Socket.prototype.setEncoding=function(e){this._enc=e;return this;};
Socket.prototype.setNoDelay=function(){return this;};
Socket.prototype.setKeepAlive=function(){return this;};
Socket.prototype.setTimeout=function(ms,cb){if(ms&&cb)this.once('timeout',cb);return this;};
Socket.prototype.__err=function(e){var self=this;var err=new Error(String(e));err.code=String(e);queueMicrotask(function(){self.emit('error',err);});};

function connect(port,host,cb){var s=new Socket();return s.connect(port,host,cb);}
def('net',{Socket:Socket,connect:connect,createConnection:connect,
  isIP:function(s){return /^\d{1,3}(\.\d{1,3}){3}$/.test(String(s))?4:0;},isIPv4:function(s){return /^\d{1,3}(\.\d{1,3}){3}$/.test(String(s));},isIPv6:function(){return false;}});

// node:dns — resolve via the host resolver (net_resolve), callback + promises forms.
function __dns_lookup(host,opts,cb){if(typeof opts==='function'){cb=opts;}
  var r=__host('net_resolve',[String(host)]);
  queueMicrotask(function(){if(r&&r.ok)cb(null,r.address,4);else cb(new Error((r&&r.err)||'ENOTFOUND'));});}
def('dns',{lookup:__dns_lookup,
  promises:{lookup:function(host){var r=__host('net_resolve',[String(host)]);return (r&&r.ok)?Promise.resolve({address:r.address,family:4}):Promise.reject(new Error((r&&r.err)||'ENOTFOUND'));}}});
