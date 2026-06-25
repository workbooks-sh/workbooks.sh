class Emitter {
  #handlers = {};
  on(e, fn) { (this.#handlers[e] ||= []).push(fn); return this; }
  emit(e, ...args) { (this.#handlers[e]||[]).forEach(fn => fn(...args)); }
}
const em = new Emitter(); let sum = 0;
em.on('add', n => sum += n).on('add', n => sum += n*2);
em.emit('add', 5); em.emit('add', 10);
console.log(sum);
