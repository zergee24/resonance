const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Sources/ResonanceApp/Resources/playlist_writer.js', 'utf8');

// Fixtures mirror the observed NetEase header: the avatar is /user/home,
// while the collapsed account menu contains a hidden /login identity link.
function page({ signedIn = true, hiddenLogin = true } = {}) {
  const clicks = [];
  const window = { getComputedStyle: () => ({ display: 'block', visibility: 'visible', opacity: '1' }) };
  const element = (kind, rendered = true) => ({
    getClientRects: () => rendered ? [{}] : [],
    ownerDocument: { defaultView: window },
    getAttribute: name => name === 'data-res-id' ? '30854130' : null,
    click: () => clicks.push(kind)
  });
  const avatar = element('avatar'), login = element('login', !hiddenLogin);
  const favorite = element('favorite'), queue = element('queue');
  const header = {
    querySelectorAll(selector) {
      if (selector.includes('a[href*=\'/login\']')) return [login];
      if (signedIn && selector.includes('.m-tophead .head a')) return [avatar];
      return [];
    }
  };
  const document = {
    defaultView: window,
    querySelector(selector) { return selector === '#g_iframe' ? null : header; },
    querySelectorAll(selector) {
      if (selector.includes('data-res-action="fav"')) return [favorite];
      if (selector.includes('data-res-action="addto"')) return [queue];
      return [];
    }
  };
  const run = vm.runInNewContext(source, { document, window });
  return { run, clicks };
}

const loggedIn = page();
assert.equal(loggedIn.run('headerState', {}).loggedIn, true, 'hidden account-menu login is not a visible login button');
const loggedOut = page({ signedIn: false, hiddenLogin: false });
assert.equal(loggedOut.run('headerState', {}).loggedIn, false, 'visible login button reports signed out');
const unknown = page({ signedIn: false });
assert.equal(unknown.run('headerState', {}).stage, 'headerIdentityUnknown', 'missing header evidence stays unknown');
assert.equal(loggedIn.run('openAdd', { trackID: '30854130' }).ok, true);
assert.deepEqual(loggedIn.clicks, ['favorite'], 'playlist writing opens 收藏, not the playback queue');
assert.equal(loggedIn.run('openAdd', { trackID: 'different' }).ok, false, 'another song must not be selected');
console.log('PASS: header visibility, signed-out/unknown state, exact song favorite action');
