import { $, state, clearError, showError, settleConfirm } from './shared.js';
import { loadCatalog, closeProbe } from './catalog.js';
import { loadUsage, resetUsage } from './usage.js';
import { loadKeyUsage, resetKeyUsage, openKeyUsage } from './key-usage.js';
import { loadAccounts, resetAccounts, openAccountSearch } from './accounts.js';
import { loadRetention, resetRetention } from './retention.js';
import { loadFeedback, resetFeedback } from './feedback.js';

// ---- 登录 ----
$('#login').addEventListener('submit', async (e) => {
  e.preventDefault();
  await signIn($('#token').value.trim());
});
$('#logout').addEventListener('click', () => logout());

async function signIn(token) {
  const button = $('#login-submit');
  if (button.disabled) return;
  button.disabled = true;
  button.textContent = '连接中…';
  clearError('login-error');
  state.token = token;
  try {
    await loadCatalog();
    sessionStorage.setItem('zhixin-admin-token', token);
    $('#token').value = '';
    showApp(true);
    tabs[0].focus({ preventScroll: true });
  } catch (err) {
    logout(err.message);
  } finally {
    button.disabled = false;
    button.textContent = '进入后台';
  }
}

function logout(msg) {
  const wasSignedIn = !$('#app').hidden;
  state.token = '';
  sessionStorage.removeItem('zhixin-admin-token');
  resetUsage();
  resetKeyUsage();
  resetRetention();
  resetAccounts();
  resetFeedback();
  state.providers = [];
  state.models = [];
  state.upstreamNames.clear();
  settleConfirm(false);
  for (const dialog of document.querySelectorAll('dialog[open]')) dialog.close();
  selectTab(tabs[0]);
  showApp(false);
  if (msg) showError('login-error', msg);
  else clearError('login-error');
  if (msg || wasSignedIn) $('#token').focus();
}

function showApp(on) {
  $('#app').hidden = !on;
  $('#session').hidden = !on;
  $('#sign-in').hidden = on;
}

// ---- 标签页 ----
const tabs = [...document.querySelectorAll('[role=tab]')];
const loaders = {
  usage: loadUsage,
  'key-usage': (userID) => userID ? openKeyUsage(userID) : loadKeyUsage(),
  accounts: (userID) => userID ? openAccountSearch(userID) : loadAccounts(),
  retention: loadRetention,
  feedback: loadFeedback,
};
const mobileTabs = matchMedia('(max-width: 760px)');
function updateTabOrientation() {
  $('.tabs').setAttribute('aria-orientation', mobileTabs.matches ? 'horizontal' : 'vertical');
}
mobileTabs.addEventListener('change', updateTabOrientation);
updateTabOrientation();

function selectTab(tab, params) {
  const changed = tab.getAttribute('aria-selected') !== 'true';
  closeProbe();
  for (const item of tabs) {
    const selected = item === tab;
    item.setAttribute('aria-selected', String(selected));
    item.tabIndex = selected ? 0 : -1;
    document.getElementById(item.getAttribute('aria-controls')).hidden = !selected;
  }
  if (changed) {
    window.scrollTo(0, 0);
    if (mobileTabs.matches) tab.scrollIntoView({ inline: 'nearest', block: 'nearest' });
  }
  if (state.token) loaders[tab.dataset.tab]?.(params);
}
tabs.forEach((tab, index) => {
  tab.addEventListener('click', () => selectTab(tab));
  tab.addEventListener('keydown', (e) => {
    const previous = (index + tabs.length - 1) % tabs.length;
    const following = (index + 1) % tabs.length;
    const next = { ArrowLeft: previous, ArrowRight: following, Home: 0, End: tabs.length - 1,
      ArrowUp: mobileTabs.matches ? undefined : previous, ArrowDown: mobileTabs.matches ? undefined : following }[e.key];
    if (next === undefined) return;
    e.preventDefault();
    tabs[next].focus();
    selectTab(tabs[next]);
  });
});


document.addEventListener('admin:navigate', ({ detail }) => {
  if (!state.token) return;
  const tab = $('#nav-' + detail.name);
  selectTab(tab, detail.params);
  tab.focus({ preventScroll: true });
});
document.addEventListener('admin:unauthorized', (event) => logout(event.detail));
if (state.token) signIn(state.token);
