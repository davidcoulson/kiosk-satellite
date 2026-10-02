import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

// The remote admin's check on a custom start page address (URL-1, T-71). The
// module imports the page's shared code, which touches the DOM at load, so
// the function is lifted out of the source and run on its own, as the other
// remote-UI tests do.
const source = readFileSync(new URL('../remote-ui/static/startpage.js', import.meta.url), 'utf8');
const start = source.indexOf('export function customStartUrlProblem(');
const end = source.indexOf('\n}\n', start) + 3;
const fn = source.slice(start, end).replace('export function', 'function');
const context = vm.createContext({ URL, String });
vm.runInContext(`${fn}; globalThis.check = customStartUrlProblem;`, context);
const problem = (text) => context.check(text);

test('an http or https page with a host is accepted', () => {
  assert.equal(problem('http://10.2.3.20:8787'), null);
  assert.equal(problem('https://panel.example/#/lobby'), null);
  assert.equal(problem('  http://10.2.3.20:8787  '), null);
});

test('anything that is not a web page is refused', () => {
  for (const bad of ['ftp://10.2.3.20/', 'file:///sdcard/x.html', 'javascript:alert(1)',
    'data:text/html,hi', '10.2.3.20:8787', 'http://', '', '   ']) {
    assert.equal(problem(bad), 'Enter a full http:// or https:// address', bad);
  }
});
