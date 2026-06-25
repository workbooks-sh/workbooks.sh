function parseCSV(text) {
  return text.trim().split('\n').map(line => line.split(',').map(c => c.trim()));
}
const rows = parseCSV('a, b, c\n1, 2, 3\n4, 5, 6');
console.log(rows.length, rows[1][2], rows.map(r => r.join('|')).join(';'));
