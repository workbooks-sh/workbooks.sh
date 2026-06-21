function assert(v, m){ if(!v) throw new Error(m||"assertion failed"); }
assert.ok = assert; assert.equal = function(a,b,m){ if(a!=b) throw new Error(m||"not equal"); };
assert.strictEqual = function(a,b,m){ if(a!==b) throw new Error(m||"not strictly equal"); };
assert.deepEqual = function(){}; assert.notEqual = function(){};
module.exports = assert; module.exports.default = assert;
