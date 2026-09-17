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
    if (path === 'api/claim' && input.claim) return respond(input.claim.response);
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

// Enter in a password field and a click on the submit button both raise the
// form's submit event, so the console is driven the way the browser drives it.
// A handler that does not cancel the default would navigate the page.
function submitAuthForm() {
  let defaultPrevented = false;
  const done = getElementById('auth-form').onsubmit({preventDefault() { defaultPrevented = true; }});
  if (!defaultPrevented) throw new Error('the submit handler let the page navigate');
  return done;
}

async function signIn() {
  getElementById('confirm-wrap').hidden = true;
  const button = getElementById('auth-submit');
  const flash = getElementById('auth-flash');
  button.textContent = 'Sign in';
  const done = submitAuthForm();
  const pending = {disabled: button.disabled, label: button.textContent, flash: flash.textContent};
  releaseLogin();
  await done;
  return {pending, finished: {disabled: button.disabled, label: button.textContent, flash: flash.textContent}};
}

// The first-run claim runs through the same form submit as signing in, with
// the confirm field shown. Both cases stop before the console loads: a
// mismatch never reaches the endpoint, and a refused claim comes back as a
// message on the form.
async function claimFlow() {
  context.showAuth(false);
  getElementById('auth-password').value = input.claim.password;
  getElementById('auth-confirm').value = input.claim.confirm;
  await submitAuthForm();
  return {
    claimCalls: calls['api/claim'] || 0,
    flash: getElementById('auth-flash').textContent,
    label: getElementById('auth-submit').textContent,
    disabled: Boolean(getElementById('auth-submit').disabled),
    confirmDisabled: Boolean(getElementById('auth-confirm').disabled),
  };
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
      verifyFlash: getElementById('verify-flash').textContent,
      log: getElementById('log').textContent,
    });
  }
  return snapshots;
}

async function statusSummary() {
  await vm.runInContext('poll()', context);
  return {
    summary: getElementById('vcfdt-produced').textContent,
    rows: getElementById('last-runs').innerHTML,
    catalogRows: getElementById('versions').innerHTML,
    catalogMeta: getElementById('version-meta').textContent,
    error: getElementById('sync-flash').textContent,
  };
}

(input.login ? signIn() : input.claim ? claimFlow() : input.polls ? pollSequence() : statusSummary()).then(result => {
  process.stdout.write(JSON.stringify(result));
}).catch(error => { console.error(error); process.exitCode = 1; });
