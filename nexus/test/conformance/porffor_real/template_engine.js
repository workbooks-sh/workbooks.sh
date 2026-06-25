function render(tpl, data) {
  return tpl.replace(/\{\{(\w+)\}\}/g, (_, k) => String(data[k] ?? ''));
}
console.log(render('Hi {{name}}, you have {{count}} msgs', {name:'Sam', count:3}));
