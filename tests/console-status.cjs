const fs = require('node:fs');
const vm = require('node:vm');
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const nodes = new Map();
function element() {
  return {
    textContent: '', value: '', hidden: false,
    get innerHTML() { return this.markup ?? this.textContent.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;'); },
    set innerHTML(value) { this.markup = value; },
    insertAdjacentHTML(position, value) {
      if (position !== 'beforeend') throw new Error(`Unsupported insertion: ${position}`);
      this.innerHTML += value;
    },
  };
}
function getElementById(id) {
  if (!nodes.has(id)) nodes.set(id, element());
  return nodes.get(id);
}
let replies = {};
let calls = {};
let releaseLogin = null;
const clock = {now: 0};
function respond(reply) {
  return {ok: reply.status < 400, status: reply.status, json: async () => reply.body};
}
const context = vm.createContext({
  document: {getElementById, createElement: element, querySelectorAll: () => []},
  fetch: async path => {
    calls[path] = (calls[path] || 0) + 1;
    if (path === 'api/login' && input.login) {
      return new Promise(resolve => { releaseLogin = () => resolve(respond(input.login)); });
    }
    if (replies[path]) return respond(replies[path]);
    if (path === 'api/bootstrap') return new Promise(() => {});
    return {ok: true, json: async () => path === 'api/status' ? input.status : {}};
  },
  setInterval: () => {},
  __clock: clock,
});
for (const match of input.html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g)) {
  vm.runInContext(match[1], context);
}
vm.runInContext('Date.now = () => __clock.now', context);
calls = {};

async function signIn() {
  getElementById('confirm-wrap').hidden = true;
  const button = getElementById('auth-submit');
  const flash = getElementById('auth-flash');
  button.textContent = 'Sign in';
  const done = button.onclick();
  const pending = {disabled: button.disabled, label: button.textContent, flash: flash.textContent};
  releaseLogin();
  await done;
  return {pending, finished: {disabled: button.disabled, label: button.textContent, flash: flash.textContent}};
}

async function pollSequence() {
  context.populateIdentity(input.identity);
  const snapshots = [];
  for (const step of input.polls) {
    clock.now = step.at;
    replies = step.responses || {};
    await context.poll();
    snapshots.push({
      bootstrapCalls: calls['api/bootstrap'] || 0,
      statusCalls: calls['api/status'] || 0,
      machineIdStatus: getElementById('machine-id-status').textContent,
      error: getElementById('sync-flash').textContent,
    });
  }
  return snapshots;
}

async function statusSummary() {
  await vm.runInContext('poll()', context);
  return {
    summary: getElementById('vcfdt-produced').textContent,
    rows: getElementById('last-runs').innerHTML,
    error: getElementById('sync-flash').textContent,
  };
}

(input.login ? signIn() : input.polls ? pollSequence() : statusSummary()).then(result => {
  process.stdout.write(JSON.stringify(result));
}).catch(error => { console.error(error); process.exitCode = 1; });
