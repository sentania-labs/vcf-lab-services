const fs = require('node:fs');
const vm = require('node:vm');
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const nodes = new Map();
function element() {
  return {
    textContent: '', value: '', hidden: false,
    get innerHTML() { return this.markup ?? this.textContent.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;'); },
    set innerHTML(value) { this.markup = value; },
  };
}
function getElementById(id) {
  if (!nodes.has(id)) nodes.set(id, element());
  return nodes.get(id);
}
const context = vm.createContext({
  document: {getElementById, createElement: element, querySelectorAll: () => []},
  fetch: async path => {
    if (path === 'api/bootstrap') return new Promise(() => {});
    return {ok: true, json: async () => path === 'api/status' ? input.status : {}};
  },
  setInterval: () => {},
});
for (const match of input.html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g)) {
  vm.runInContext(match[1], context);
}
vm.runInContext('poll()', context).then(() => {
  process.stdout.write(JSON.stringify({
    summary: getElementById('vcfdt-produced').textContent,
    rows: getElementById('last-runs').innerHTML,
    error: getElementById('sync-flash').textContent,
  }));
}).catch(error => { console.error(error); process.exitCode = 1; });
