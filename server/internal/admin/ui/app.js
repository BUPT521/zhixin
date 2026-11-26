// 知新模型后台。只调用 /admin/v1/ 接口，令牌放在 sessionStorage，关闭标签页即失效。
// 所有来自接口的文字一律用 textContent 写入，不拼 HTML。
'use strict';

const $ = (sel) => document.querySelector(sel);
const state = {
  token: sessionStorage.getItem('zhixin-admin-token') || '',
  providers: [], models: [], upstreamNames: new Map(), usage: null, keyUsage: null, retention: null,
  accounts: [], accountTotal: 0, accountLimit: 20, accountOffset: 0, accountQuery: '',
  feedback: [], feedbackTotal: 0, feedbackLimit: 20, feedbackOffset: 0, feedbackQuery: '',
};

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') node.className = v;
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else if (v === true) node.setAttribute(k, '');
    else if (v !== false && v != null) node.setAttribute(k, v);
  }
  for (const c of children.flat()) {
    if (c == null || c === false) continue;
    node.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return node;
}

function toast(msg) {
  const t = $('#toast');
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { t.hidden = true; }, 2600);
}

async function api(method, path, body, signal) {
  const token = state.token;
  const res = await fetch('/admin/v1' + path, {
    method,
    headers: { Authorization: 'Bearer ' + token, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
    signal,
  });
  if (res.status === 204) return null;
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const unauthorized = res.status === 401;
    const message = unauthorized ? '管理令牌不正确或已失效。' : problemText(data, res.status);
    if (unauthorized && token === state.token && !$('#app').hidden) logout(message);
    const err = new Error(message);
    err.data = data;
    throw err;
  }
  return data;
}

function problemText(p, status) {
  const parts = [p.detail || p.title || ('HTTP ' + status)];
  if (p.extra && Array.isArray(p.extra.models) && p.extra.models.length) parts.push('相关模型：' + p.extra.models.join('、'));
  return parts.join('。');
}

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
    await loadAll();
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
  usageRequest?.abort();
  retentionRequest?.abort();
  accountRequest?.abort();
  feedbackRequest?.abort();
  state.usage = null;
  state.retention = null;
  usageFilters = {};
  usageDay = null;
  state.accounts = [];
  state.accountTotal = 0;
  state.accountOffset = 0;
  state.accountQuery = '';
  state.feedback = [];
  state.feedbackTotal = 0;
  state.feedbackOffset = 0;
  state.feedbackQuery = '';
  state.upstreamNames.clear();
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
const mobileTabs = matchMedia('(max-width: 760px)');
function updateTabOrientation() {
  $('.tabs').setAttribute('aria-orientation', mobileTabs.matches ? 'horizontal' : 'vertical');
}
mobileTabs.addEventListener('change', updateTabOrientation);
updateTabOrientation();

function selectTab(tab) {
  const changed = tab.getAttribute('aria-selected') !== 'true';
  closeProbe();
  for (const item of tabs) {
    const selected = item === tab;
    item.setAttribute('aria-selected', String(selected));
    item.tabIndex = selected ? 0 : -1;
    document.getElementById(item.getAttribute('aria-controls')).hidden = !selected;
  }
  if (changed) window.scrollTo(0, 0);
  if (tab.dataset.tab === 'usage') loadUsage();
  if (tab.dataset.tab === 'retention') loadRetention();
  if (tab.dataset.tab === 'accounts') loadAccounts();
  if (tab.dataset.tab === 'feedback') loadFeedback();
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

async function loadAll() {
  const [p, m] = await Promise.all([api('GET', '/providers'), api('GET', '/models')]);
  state.providers = p.data;
  state.models = m.data;
  renderProviders();
  renderModels();
  if ($('#model-dialog').open) renderRoutePreview();
}

function refresh() {
  return loadAll().catch((err) => toast(err.message));
}

// ---- 弹窗 ----
function markClean(form) {
  form.dataset.snapshot = snapshotForm(form);
}

function snapshotForm(form) {
  const data = new FormData(form);
  return JSON.stringify([...data.entries()]);
}

function isDirty(form) {
  return Boolean(form.dataset.snapshot) && form.dataset.snapshot !== snapshotForm(form);
}

async function requestClose(id) {
  const dialog = document.getElementById(id);
  if (!dialog.open) return;
  const form = dialog.querySelector('form');
  if (form && isDirty(form)) {
    const discard = await askConfirm({
      title: '放弃未保存的修改？',
      message: '这个弹窗里填写的内容还没有保存，关闭之后不会保留。',
      ok: '放弃修改',
      danger: true,
    });
    if (!discard) return;
  }
  dialog.close();
}

document.querySelectorAll('[data-close]').forEach((button) => {
  button.addEventListener('click', () => requestClose(button.dataset.close));
});
document.querySelectorAll('dialog').forEach((dialog) => {
  if (dialog.id === 'confirm-dialog') return;
  dialog.addEventListener('click', (event) => {
    if (event.target === dialog) requestClose(dialog.id);
  });
});

// Escape 不交给浏览器的关闭请求：新版 Edge 里 cancel 事件不可取消，直接关掉会
// 绕过未保存确认。表单弹窗用 closedby="none" 关掉原生退出，这里自己处理。
document.addEventListener('keydown', (event) => {
  if (event.key !== 'Escape') return;
  const top = [...document.querySelectorAll('dialog[open]')].at(-1);
  if (!top || top.id === 'confirm-dialog') return;
  if (event.target instanceof HTMLSelectElement) return;
  if (event.target instanceof HTMLInputElement && event.target.list) return;
  event.preventDefault();
  event.stopPropagation();
  requestClose(top.id);
}, true);

let confirmState = null;
function askConfirm({ title, message, ok = '确定', danger = false }) {
  if (confirmState) settleConfirm(false);
  $('#confirm-title').textContent = title;
  $('#confirm-message').textContent = message;
  const accept = $('#confirm-ok');
  accept.textContent = ok;
  accept.classList.toggle('danger-solid', danger);
  $('#confirm-dialog').showModal();
  return new Promise((resolve) => { confirmState = { resolve }; });
}

function settleConfirm(value) {
  const dialog = $('#confirm-dialog');
  if (dialog.open) dialog.close();
  const current = confirmState;
  confirmState = null;
  current?.resolve(value);
}

$('#confirm-cancel').addEventListener('click', () => settleConfirm(false));
$('#confirm-ok').addEventListener('click', () => settleConfirm(true));
$('#confirm-dialog').addEventListener('cancel', (event) => {
  event.preventDefault();
  settleConfirm(false);
});
$('#confirm-dialog').addEventListener('click', (event) => {
  if (event.target === $('#confirm-dialog')) settleConfirm(false);
});

function showError(id, message, focus) {
  const box = document.getElementById(id);
  box.textContent = message;
  box.hidden = false;
  box.scrollIntoView({ block: 'nearest' });
  if (focus) focus.focus();
}

function clearError(id) {
  const box = document.getElementById(id);
  box.textContent = '';
  box.hidden = true;
}

async function runSave(button, action, errorID) {
  if (button.disabled) return;
  const label = button.textContent;
  button.disabled = true;
  button.textContent = '保存中…';
  clearError(errorID);
  try {
    await action();
  } catch (err) {
    showError(errorID, err.message);
  } finally {
    button.disabled = false;
    button.textContent = label;
  }
}

// ---- 来源 ----
function providerLabel(id) {
  const provider = state.providers.find((item) => item.id === id);
  return provider && provider.name && provider.name !== provider.id ? provider.name : id;
}

function providerOption(provider) {
  const name = provider.name && provider.name !== provider.id ? `${provider.name}（${provider.id}）` : provider.id;
  return provider.enabled ? name : name + '（已停用）';
}

function renderProviders() {
  const body = $('#providers');
  body.replaceChildren();
  const enabled = state.providers.filter((p) => p.enabled).length;
  const missingKey = state.providers.filter((p) => !p.has_key).length;
  $('#provider-summary').textContent = state.providers.length
    ? `${state.providers.length} 个来源 · ${enabled} 个启用` + (missingKey ? ` · ${missingKey} 个未设置密钥` : '')
    : '';
  if (!state.providers.length) {
    body.append(el('tr', {}, el('td', { colspan: 5, class: 'empty' }, '还没有来源。点“新增来源”，先填地址和密钥。')));
    return;
  }
  for (const p of state.providers) {
    const health = p.health || {};
    const title = p.name && p.name !== p.id ? p.name : p.id;
    const details = [];
    let badge = '正常';
    let tone = 'ok';
    if (!p.enabled) {
      badge = '已停用';
      tone = 'off';
    } else if (health.state === 'key_error') {
      badge = '密钥异常';
      tone = 'key_error';
    } else if (['cooling', 'probe_ready', 'probing'].includes(health.state)) {
      badge = routeState[health.state];
      tone = 'cooling';
    }
    if (p.enabled) {
      if (health.consecutive_failures) details.push(`连续失败 ${health.consecutive_failures} 次`);
      if (health.cooling_until) details.push('冷却到 ' + clock(health.cooling_until));
      if (health.last_error) details.push('最近错误：' + health.last_error);
    }
    body.append(el('tr', {},
      el('td', { class: 'source-cell' },
        el('div', { class: 'source-name' }, title),
        p.name && p.name !== p.id ? el('div', { class: 'mono sub' }, p.id) : null,
        p.note ? el('div', { class: 'sub' }, p.note) : null,
      ),
      el('td', { class: 'mono url', 'data-label': '基础地址' }, p.base_url),
      el('td', { 'data-label': '密钥' },
        p.has_key
          ? el('div', {}, el('span', { class: 'mono' }, '••••' + (p.key_hint || '')), el('div', { class: 'sub' }, '已保存'))
          : el('span', { class: 'badge warn' }, '未设置'),
      ),
      el('td', { 'data-label': '状态' },
        el('span', { class: 'badge ' + tone }, badge),
        details.map((text) => el('div', { class: 'sub status-detail', title: health.last_error_at || '' }, text)),
      ),
      el('td', { class: 'ops' }, el('div', { class: 'row-actions' },
        el('button', { type: 'button', class: 'link', 'aria-label': `测试来源 ${p.id}`, onclick: () => testProvider(p) }, '测试'),
        el('button', { type: 'button', class: 'link', 'aria-label': `编辑来源 ${p.id}`, onclick: () => editProvider(p) }, '编辑'),
        el('button', { type: 'button', class: 'danger', 'aria-label': `删除来源 ${p.id}`, onclick: () => deleteProvider(p) }, '删除'),
      )),
    ));
  }
}

function clock(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';
  return date.toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
}

$('#add-provider').addEventListener('click', () => editProvider(null));

let editingProvider = null;

function editProvider(p) {
  editingProvider = p;
  const form = $('#provider-form');
  const f = form.elements;
  form.reset();
  f.id.value = p ? p.id : '';
  f.id.readOnly = Boolean(p);
  f.name.value = p ? p.name : '';
  f.base_url.value = p ? p.base_url : '';
  f.api_key.value = '';
  f.api_key.disabled = false;
  f.clear_key.checked = false;
  f.clear_key.closest('label').hidden = !(p && p.has_key);
  f.enabled.checked = p ? p.enabled : true;
  f.note.value = p ? p.note : '';
  $('#provider-title').textContent = p ? '编辑来源 ' + p.id : '新增来源';
  $('#provider-desc').textContent = p ? '修改保存之后立即生效，用到这个来源的路由会重新读取。' : '密钥加密保存在服务端，保存之后只显示末四位。';
  $('#provider-id-hint').textContent = p ? '编号保存后不能修改；换地址要同时重新填写 key' : '用于路由引用；小写字母、数字、- 或 _，保存后不能修改，也不能与已有编号重复';
  updateProviderKeyHint();
  clearError('provider-error');
  $('#provider-dialog').showModal();
  markClean(form);
  (p ? f.name : f.id).focus();
}

function normalizeBaseURL(value) {
  const raw = value.trim();
  if (!raw) return null;
  try {
    const url = new URL(raw);
    if (!['http:', 'https:'].includes(url.protocol) || !url.host || url.username || url.password || url.search || url.hash) return null;
    return url.toString().replace(/\/+$/, '');
  } catch {
    return null;
  }
}

function updateProviderKeyHint() {
  const form = $('#provider-form');
  const f = form.elements;
  const p = editingProvider;
  const hint = $('#provider-key-hint');
  hint.classList.remove('warn');
  if (!p || !p.has_key) {
    hint.textContent = '没有 key 时留空；保存后会加密，不再明文显示。';
    return;
  }
  if (f.clear_key.checked) {
    hint.textContent = '保存后会清除已保存的 key。';
    return;
  }
  const base = normalizeBaseURL(f.base_url.value);
  if (base && base !== p.base_url) {
    hint.textContent = '基础地址改过了，保存时必须重新填写 key。';
    hint.classList.add('warn');
    return;
  }
  hint.textContent = `已保存末四位 ${p.key_hint || ''}；留空表示不修改。`;
}

$('#provider-form').elements.base_url.addEventListener('input', updateProviderKeyHint);
$('#provider-form').elements.clear_key.addEventListener('change', (event) => {
  const key = $('#provider-form').elements.api_key;
  key.disabled = event.target.checked;
  if (event.target.checked) key.value = '';
  updateProviderKeyHint();
});
$('#provider-form').addEventListener('input', () => clearError('provider-error'));

$('#provider-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const form = event.target;
  const f = form.elements;
  const base = normalizeBaseURL(f.base_url.value);
  if (!base) {
    showError('provider-error', '基础地址要写成完整的 http 或 https 地址，不带查询串与片段。', f.base_url);
    return;
  }
  if (/\/(chat\/completions|embeddings)$/.test(base)) {
    showError('provider-error', '基础地址不要带 /responses 或 /embeddings，服务端会自己拼上。', f.base_url);
    return;
  }
  const key = f.api_key.value.trim();
  if (key && /\s/.test(key)) {
    showError('provider-error', 'API key 不能包含空格或换行。', f.api_key);
    return;
  }
  if (editingProvider && editingProvider.has_key && base !== editingProvider.base_url && !key && !f.clear_key.checked) {
    showError('provider-error', '基础地址改过了，请重新填写 API key。', f.api_key);
    return;
  }
  const body = { base_url: base, name: f.name.value.trim(), enabled: f.enabled.checked, note: f.note.value.trim() };
  if (key) body.api_key = key;
  else if (f.clear_key.checked) body.api_key = '';
  const id = f.id.value.trim();
  const editing = Boolean(editingProvider);
  await runSave($('#provider-save'), async () => {
    try {
      if (editing) await api('PUT', '/providers/' + encodeURIComponent(id), body);
      else await api('POST', '/providers', { ...body, id });
    } catch (err) {
      if (err.data?.code === 'conflict') {
        await refresh();
        throw new Error(`编号 ${id} 已经被占用；要修改它请关闭弹窗，在列表里点“编辑”，或换一个编号。`);
      }
      throw err;
    }
    state.upstreamNames.delete(id);
    $('#provider-dialog').close();
    toast(editing ? '已保存，路由立即生效' : `已新增来源 ${id}`);
    refresh();
  }, 'provider-error');
});

async function deleteProvider(p) {
  const ok = await askConfirm({
    title: '删除这个来源？',
    message: `删除 ${p.id} 之后无法恢复。还有模型路由指向它时，服务端会拒绝删除并列出相关模型。`,
    ok: '删除',
    danger: true,
  });
  if (!ok) return;
  try {
    await api('DELETE', '/providers/' + encodeURIComponent(p.id));
    state.upstreamNames.delete(p.id);
    toast('已删除来源 ' + p.id);
    refresh();
  } catch (err) { toast(err.message); }
}

async function testProvider(p) {
  const signal = beginProbe(`测试来源 ${p.id}：请求 ${p.base_url}/models`);
  try {
    const r = await api('POST', '/providers/' + encodeURIComponent(p.id) + '/test', null, signal);
    if (signal.aborted) return;
    const names = r.models || [];
    if (r.ok) state.upstreamNames.set(p.id, names);
    showProbe(`测试来源 ${p.id}`,
      el('p', {}, el('span', { class: r.ok ? 'ok' : 'bad' }, r.ok ? '可用' : '不可用'),
        `　耗时 ${r.latency_ms} ms`, r.status ? `　HTTP ${r.status}` : ''),
      r.error ? el('p', {}, r.error) : null,
      names.length ? el('p', { class: 'sub' }, `来源列出 ${names.length} 个模型，编辑模型路由时可以直接选：`) : null,
      names.length ? el('div', { class: 'chips mono' }, names.map((n) => el('span', {}, n))) : null,
    );
  } catch (err) {
    if (!signal.aborted) showProbe('测试失败', el('p', {}, err.message));
  }
}

// ---- 模型 ----
const routeState = {
  ready: '可用', cooling: '冷却中', probe_ready: '待试探', probing: '试探中', disabled: '路由停用',
  provider_disabled: '来源停用', key_error: '密钥异常', provider_missing: '来源缺失',
};
const routeBadge = {
  ready: 'ok', cooling: 'cooling', probe_ready: 'cooling', probing: 'cooling', disabled: 'off',
  provider_disabled: 'off', key_error: 'key_error', provider_missing: 'key_error',
};
const kindName = { chat: '聊天', embedding: '嵌入' };
const kindList = ['chat', 'embedding'];
const MAX_ROUTES = 16;
const MAX_ROUTE_PRIORITY = 100;
const modelFilter = { query: '', kind: 'all', attention: false };
const quickBusy = new Set();

$('#model-search').addEventListener('input', (event) => {
  modelFilter.query = event.target.value.trim().toLowerCase();
  renderModels();
});
$('#model-kind').addEventListener('change', (event) => {
  modelFilter.kind = event.target.value;
  renderModels();
});
$('#model-attention').addEventListener('change', (event) => {
  modelFilter.attention = event.target.checked;
  renderModels();
});

function providerHealth(id) {
  return state.providers.find((p) => p.id === id)?.health || {};
}

function routeHealthText(route) {
  if (['disabled', 'provider_disabled', 'provider_missing', 'key_error'].includes(route.state)) return [];
  return [['来源', providerHealth(route.provider_id)], ['路由', route.health]].flatMap(([label, health]) => {
    if (!health?.consecutive_failures) return [];
    const until = health.cooling_until ? `，冷却到 ${clock(health.cooling_until)}` : '';
    return [el('span', { class: 'route-health', title: health.last_error || '' },
      `${label}连续失败 ${health.consecutive_failures} 次${until}`)];
  });
}

function modelNeedsAttention(m) {
  return !m.enabled || !m.available ||
    m.routes.some((r) => r.state !== 'ready' && r.state !== 'disabled') ||
    m.routes.every((r) => !r.enabled);
}

function matchesModel(m) {
  if (modelFilter.kind !== 'all' && m.kind !== modelFilter.kind) return false;
  if (modelFilter.attention && !modelNeedsAttention(m)) return false;
  if (!modelFilter.query) return true;
  const text = [m.name, m.note, kindName[m.kind],
    ...m.routes.flatMap((r) => [r.provider_id, providerLabel(r.provider_id), r.upstream_model])].join(' ').toLowerCase();
  return text.includes(modelFilter.query);
}

function moment(value) {
  const date = new Date(value);
  if (!value || Number.isNaN(date.getTime())) return '';
  return date.toLocaleString('zh-CN', { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' });
}

function renderModels() {
  const body = $('#models');
  body.replaceChildren();
  const routes = state.models.flatMap((m) => m.routes);
  const available = state.models.filter((m) => m.available).length;
  const cooling = routes.filter((r) => r.state === 'cooling').length;
  const attention = state.models.filter(modelNeedsAttention).length;
  $('#model-summary').textContent = state.models.length
    ? `${state.models.length} 个模型 · ${available} 个可调用 · ${routes.length} 条路由` +
      (cooling ? ` · ${cooling} 条冷却中` : '') + (attention ? ` · ${attention} 个需要注意` : '')
    : '';
  const shown = state.models.filter(matchesModel);
  $('#model-filter-count').textContent = state.models.length && shown.length !== state.models.length
    ? `显示 ${shown.length} / ${state.models.length} 个模型`
    : '';
  if (!state.models.length) {
    body.append(el('tr', {}, el('td', { colspan: 4, class: 'empty' }, '还没有对外模型。先新增来源，再新增模型并配置路由。')));
    return;
  }
  if (!shown.length) {
    body.append(el('tr', {}, el('td', { colspan: 4, class: 'empty' }, '没有符合筛选条件的模型。')));
    return;
  }
  for (const m of shown) {
    const usable = m.routes.filter(routeEligible).length;
    const tone = !m.enabled ? 'off' : m.available ? 'ok' : 'warn';
    const label = !m.enabled ? '已停用' : m.available ? '可调用' : '当前无可用路由';
    const updated = moment(m.updated_at);
    body.append(el('tr', {},
      el('td', { class: 'model-cell' },
        el('div', { class: 'model-title' },
          el('span', { class: 'mono model-name' }, m.name),
          el('span', { class: 'tag' }, kindName[m.kind]),
          m.dimensions ? el('span', { class: 'tag muted' }, m.dimensions + ' 维') : null,
        ),
        m.note ? el('div', { class: 'sub' }, m.note) : null,
        updated ? el('div', { class: 'sub' }, '更新于 ' + updated) : null,
      ),
      el('td', { class: 'routes-cell', 'data-label': '路由' }, renderRouteList(m)),
      el('td', { 'data-label': '状态' },
        el('span', { class: 'badge ' + tone }, label),
        el('div', { class: 'sub' }, usable === m.routes.length ? `${m.routes.length} 条路由` : `${usable}/${m.routes.length} 条路由可用`),
      ),
      el('td', { class: 'ops' }, el('div', { class: 'row-actions' },
        el('button', { type: 'button', class: 'link', disabled: !m.available, 'aria-label': `测试模型 ${m.name}`, onclick: () => testModel(m) }, '测试模型'),
        el('button', { type: 'button', class: 'link', 'aria-label': `编辑模型 ${m.name}`, onclick: () => editModel(m) }, '编辑'),
        el('button', { type: 'button', class: 'link', 'aria-label': `按 ${m.name} 的路由复制一个新模型`, onclick: () => editModel(m, { copy: true }) }, '复制'),
        el('button', { type: 'button', class: 'link', 'aria-label': `${m.enabled ? '停用' : '启用'}模型 ${m.name}`, onclick: () => toggleModel(m) }, m.enabled ? '停用' : '启用'),
        el('button', { type: 'button', class: 'danger', 'aria-label': `删除模型 ${m.name}`, onclick: () => deleteModel(m) }, '删除'),
      )),
    ));
  }
}

function routeGroupName(index) {
  return index === 0 ? '主用组' : `备用组 ${index}`;
}

function routeGroups(routes) {
  const groups = new Map();
  for (const route of routes) {
    if (!groups.has(route.priority)) groups.set(route.priority, []);
    groups.get(route.priority).push(route);
  }
  return [...groups].sort(([a], [b]) => a - b);
}

function routeEligible(route) {
  return route.state === 'ready' || route.state === 'probe_ready';
}

function candidateGroups(groups) {
  return groups.map(({ name, routes }) => ({ name, routes: routes.filter(routeEligible) }))
    .filter((group) => group.routes.length);
}

function routeWeight(routes) {
  return routes.reduce((total, route) => total + route.weight, 0);
}

function routeShare(value) {
  return value > 0 && value < 0.001 ? '<0.1%' : percent.format(value);
}

function renderRouteList(m) {
  if (!m.routes.length) return el('span', { class: 'sub' }, '没有路由');
  const groups = routeGroups(m.routes).map(([, routes], index) => ({
    name: routeGroupName(index), routes,
  }));
  const first = candidateGroups(groups)[0]?.routes || [];
  const total = routeWeight(first);
  const out = [];
  for (const { name, routes } of groups) {
    const groupTotal = routeWeight(routes.filter((route) => route.enabled));
    const ordered = [...routes].sort((a, b) =>
      a.provider_id.localeCompare(b.provider_id) || a.upstream_model.localeCompare(b.upstream_model));
    out.push(el('div', { class: 'route-group' }, name));
    for (const route of ordered) {
      const share = first.includes(route) ? route.weight / total : null;
      const configuredShare = route.enabled ? route.weight / groupTotal : null;
      out.push(routeRow(m, route, share, configuredShare));
    }
  }
  return out;
}

function routeRow(m, r, firstShare, configuredShare) {
  const meta = [];
  if (configuredShare !== null) meta.push(`同组配置比例 ${routeShare(configuredShare)}`);
  if (firstShare !== null) meta.push(`当前首选 ${routeShare(firstShare)}`);
  else if (routeEligible(r)) meta.push('仅在失败后尝试');
  if (m.kind === 'embedding' && r.max_batch) meta.push(`每批 ${r.max_batch} 条`);
  // 能力标记只显示例外：关掉的才不会接对应的请求。
  if (r.supports_tools === false) meta.push('不接工具请求');
  if (r.supports_images === false) meta.push('不带图片');
  return el('div', { class: 'route' + (routeEligible(r) ? '' : ' is-off') },
    el('div', { class: 'route-main' },
      el('span', { class: 'mono route-name', title: r.provider_id }, providerLabel(r.provider_id) + ' → ' + r.upstream_model),
      el('span', { class: 'badge ' + (routeBadge[r.state] || 'off') }, routeState[r.state] || r.state),
      meta.length ? el('span', { class: 'route-meta' }, meta.join(' · ')) : null,
      routeHealthText(r),
    ),
    el('span', { class: 'route-ops' },
      el('button', { type: 'button', class: 'link', disabled: !(routeEligible(r) || r.state === 'cooling'),
        'aria-label': `探测 ${m.name} 的 ${r.provider_id} / ${r.upstream_model} 路由`,
        onclick: () => testModel(m, r) }, '探测'),
      el('button', { type: 'button', class: 'link', 'aria-label': `查看 ${m.name} 的 ${r.provider_id} / ${r.upstream_model} 路由用量`,
        onclick: () => openRouteUsage(m, r) }, '用量'),
      el('button', { type: 'button', class: 'link', 'aria-label': `${r.enabled ? '停用' : '启用'} ${m.name} 的 ${r.provider_id} / ${r.upstream_model} 路由`,
        onclick: () => toggleRoute(m, r) }, r.enabled ? '停用' : '启用'),
    ),
  );
}

// routeInput 把列表里的路由还原成管理接口的输入；聊天路由不带 max_batch，
// 避免把一个只对嵌入有意义的字段写进聊天模型。
function routeInput(m, r) {
  const out = {
    provider_id: r.provider_id, upstream_model: r.upstream_model,
    priority: r.priority, weight: r.weight, enabled: r.enabled,
    supports_tools: r.supports_tools !== false, supports_images: r.supports_images !== false,
  };
  if (m.kind === 'embedding') out.max_batch = r.max_batch;
  return out;
}

function modelInput(m, changes = {}) {
  const body = {
    kind: m.kind, enabled: m.enabled, note: m.note || '',
    routes: m.routes.map((r) => routeInput(m, r)),
  };
  if (m.kind === 'embedding' && m.dimensions) body.dimensions = m.dimensions;
  return Object.assign(body, changes);
}

// quickUpdate 用模型名作锁：整体保存的请求互相覆盖，同一个模型的两处快捷操作
// 不能并发，否则后到的请求会把前一次改动带回旧值。
async function quickUpdate(m, body, message) {
  if (quickBusy.has(m.name)) return;
  quickBusy.add(m.name);
  try {
    const saved = await api('PUT', '/models/' + encodeURIComponent(m.name), body);
    const index = state.models.findIndex((item) => item.name === m.name);
    if (index >= 0) state.models[index] = saved;
    renderModels();
    toast(message);
  } catch (err) {
    toast(err.message);
    refresh();
  } finally {
    quickBusy.delete(m.name);
  }
}

function toggleModel(m) {
  const enabled = !m.enabled;
  quickUpdate(m, modelInput(m, { enabled }),
    enabled ? `已启用模型 ${m.name}` : `已停用模型 ${m.name}`);
}

function toggleRoute(m, r) {
  const routes = m.routes.map((route) => routeInput(m, route));
  const target = routes.find((route) => route.provider_id === r.provider_id && route.upstream_model === r.upstream_model);
  if (!target) return;
  target.enabled = !r.enabled;
  quickUpdate(m, modelInput(m, { routes }),
    target.enabled ? `已启用 ${m.name} 的这条路由` : `已停用 ${m.name} 的这条路由`);
}

$('#add-model').addEventListener('click', () => editModel(null));
$('#refresh-models').addEventListener('click', refresh);
$('#add-route').addEventListener('click', () => {
  const row = addRouteRow({}, $('#route-rows').firstElementChild);
  updateRouteControls();
  row.querySelector('[name="provider_id"]').focus();
});
$('#model-form').elements.kind.addEventListener('change', () => {
  syncKind();
  renderRoutePreview();
});
$('#model-form').addEventListener('input', (event) => {
  clearError('model-error');
  if (event.target.closest('#route-rows') || event.target.name === 'enabled') renderRoutePreview();
});
$('#route-scenario').addEventListener('change', renderRoutePreview);

function syncKind() {
  const form = $('#model-form');
  const emb = form.elements.kind.value === 'embedding';
  form.classList.toggle('is-embedding', emb);
  document.querySelectorAll('#model-dialog .emb-only').forEach((node) => { node.hidden = !emb; });
}

let routeRowID = 0;

function addRouteGroup(priority) {
  const group = el('section', { class: 'route-edit-group', 'data-priority': priority },
    el('h4', { class: 'route-edit-title' }),
    el('div', { class: 'route-edit-members' }),
    el('p', { class: 'field-hint route-edit-empty', hidden: true }, '主用组为空，保存后会从首个备用组开始尝试。'),
  );
  $('#route-rows').append(group);
  return group;
}

function moveRoute(row, priority) {
  const groups = [...$('#route-rows').children];
  let group = groups.find((item) => item.dataset.priority === priority);
  if (priority === 'new') {
    let next = Number(groups.at(-1).dataset.priority) + 1;
    if (next > MAX_ROUTE_PRIORITY) {
      // 已用到最大编号时，按现有组顺序分配连续编号，给新增组留出位置。
      groups.forEach((item, index) => { item.dataset.priority = index; });
      next = groups.length;
    }
    group = addRouteGroup(next);
  }
  const members = group.querySelector('.route-edit-members');
  const next = [...members.children].find((member) => Number(member.dataset.position) > Number(row.dataset.position));
  members.insertBefore(row, next || null);
  updateRouteControls();
  row.querySelector('[name="priority"]').focus();
}

function addRouteRow(route, group) {
  const suffix = ++routeRowID;
  const datalist = el('datalist', { id: 'upstream-names-' + suffix });
  const select = el('select', { name: 'provider_id', required: true },
    state.providers.map((p) => el('option', { value: p.id, selected: p.id === route.provider_id }, providerOption(p))));
  if (route.provider_id && !state.providers.some((p) => p.id === route.provider_id)) {
    select.append(el('option', { value: route.provider_id, selected: true }, `${route.provider_id}（来源缺失）`));
  }
  const input = el('input', {
    name: 'upstream_model', required: true, maxlength: 128, list: datalist.id,
    value: route.upstream_model || '', placeholder: '例如 deepseek-chat、BAAI/bge-m3',
    autocomplete: 'off', spellcheck: 'false', 'aria-label': '来源侧模型名',
  });
  const refreshSuggestions = () => {
    datalist.replaceChildren(...(state.upstreamNames.get(select.value) || []).map((name) => el('option', { value: name })));
  };
  select.addEventListener('change', refreshSuggestions);
  refreshSuggestions();
  const discover = el('button', { type: 'button', class: 'ghost small', 'aria-label': '读取这个来源的模型列表' }, '读取列表');
  discover.addEventListener('click', async () => {
    const provider = select.value;
    if (!provider) return;
    const label = discover.textContent;
    discover.disabled = true;
    discover.textContent = '读取中…';
    try {
      const result = await api('POST', '/providers/' + encodeURIComponent(provider) + '/test');
      if (!result.ok) throw new Error(result.error || '无法获取模型列表');
      const names = result.models || [];
      state.upstreamNames.set(provider, names);
      refreshSuggestions();
      toast(names.length ? `已读取 ${names.length} 个模型，可在模型名输入框中选择` : '来源没有列出模型，可以手工填写');
    } catch (err) {
      toast(err.message);
    } finally {
      discover.disabled = false;
      discover.textContent = label;
    }
  });
  const priority = el('select', { name: 'priority', onchange: () => moveRoute(row, priority.value) });
  const weight = el('input', { name: 'weight', type: 'number', min: 1, max: 1000, step: 1, inputmode: 'numeric', value: route.weight ?? 1, title: '同一讨论固定从同一条路由开始，权重决定会话落到各条路由的比例' });
  const batch = el('input', { name: 'max_batch', type: 'number', min: 0, max: 2048, step: 1, inputmode: 'numeric', value: route.max_batch ?? 0, title: '0 表示不拆分' });
  const enabled = el('input', { name: 'route_enabled', type: 'checkbox', checked: route.enabled ?? true });
  const tools = el('input', { name: 'supports_tools', type: 'checkbox', checked: route.supports_tools ?? true });
  const images = el('input', { name: 'supports_images', type: 'checkbox', checked: route.supports_images ?? true });
  const row = el('div', { class: 'route-edit', 'data-position': suffix },
    el('label', { class: 'route-field field-provider' },
      el('span', { class: 'field-label' }, '来源'),
      select,
    ),
    el('div', { class: 'route-field field-upstream' },
      el('span', { class: 'field-label' }, '来源侧模型名'),
      el('div', { class: 'input-action' }, input, discover),
      datalist,
    ),
    el('label', { class: 'route-field field-group' },
      el('span', { class: 'field-label' }, '路由组'),
      priority,
    ),
    el('label', { class: 'route-field field-weight' },
      el('span', { class: 'field-label' }, '会话权重'),
      el('span', { class: 'weight-input' }, weight, el('span', { class: 'field-hint route-config-share', 'aria-hidden': 'true' })),
    ),
    el('label', { class: 'route-field field-num emb-only' },
      el('span', { class: 'field-label' }, '每批条数'),
      batch,
    ),
    el('label', { class: 'check route-enabled' }, enabled, '启用'),
    el('label', { class: 'check route-tools', title: '按实际调用核对过函数调用；关掉之后带 tools 的请求不会走这条路由' }, tools, '工具'),
    el('label', { class: 'check route-images', title: '按实际调用核对过图片输入；关掉之后带图片的请求不会走这条路由' }, images, '图片'),
    el('button', { type: 'button', class: 'link danger route-remove', onclick: () => {
      row.remove();
      updateRouteControls();
    } }, '移除'),
  );
  group.querySelector('.route-edit-members').append(row);
  return row;
}

function updateRouteControls() {
  const groups = [...$('#route-rows').children].filter((group, index) => {
    if (index === 0 || group.querySelector('.route-edit')) return true;
    group.remove();
    return false;
  });
  const rows = [...$('#route-rows').querySelectorAll('.route-edit')];
  const add = $('#add-route');
  add.disabled = rows.length >= MAX_ROUTES;
  add.textContent = rows.length >= MAX_ROUTES ? `已达 ${MAX_ROUTES} 条上限` : '添加路由';
  for (const [index, group] of groups.entries()) {
    const members = group.querySelectorAll('.route-edit');
    group.querySelector('.route-edit-title').textContent = routeGroupName(index);
    group.querySelector('.route-edit-empty').hidden = members.length > 0;
    for (const row of members) {
      const select = row.querySelector('[name="priority"]');
      select.replaceChildren(...groups.map((item, i) => el('option', { value: item.dataset.priority }, routeGroupName(i))),
        el('option', { value: 'new' }, '新建备用组'));
      select.value = group.dataset.priority;
      const single = members.length < 2;
      const weight = row.querySelector('[name="weight"]');
      if (single && !weight.validity.valid) weight.value = weight.defaultValue;
      row.querySelector('.field-weight').hidden = single;
      const remove = row.querySelector('.route-remove');
      remove.disabled = rows.length <= 1;
      remove.title = rows.length <= 1 ? '至少保留一条路由' : '移除这条路由';
    }
  }
  $('#model-route-count').textContent = rows.length ? `${rows.length} 条路由` : '';
  syncKind();
  renderRoutePreview();
}

function readRouteRow(row) {
  const weight = row.querySelector('[name="weight"]');
  return {
    provider_id: row.querySelector('[name="provider_id"]').value,
    upstream_model: row.querySelector('[name="upstream_model"]').value.trim(),
    priority: Number(row.querySelector('[name="priority"]').value),
    weight: weight.validity.valid ? Number(weight.value || 1) : NaN,
    enabled: row.querySelector('[name="route_enabled"]').checked,
    supports_tools: row.querySelector('[name="supports_tools"]').checked,
    supports_images: row.querySelector('[name="supports_images"]').checked,
  };
}

function renderRoutePreview() {
  const fields = $('#model-form').elements;
  const modelEnabled = fields.enabled.checked;
  const providers = new Map(state.providers.map((provider) => [provider.id, provider]));
  const current = editingModel && state.models.find((model) => model.name === editingModel.name && model.kind === fields.kind.value);
  const currentRoutes = new Map((current?.routes || []).map((r) => [JSON.stringify([r.provider_id, r.upstream_model]), r.health.state]));
  const groups = [...$('#route-rows').children].map((group, index) => {
    const rows = [...group.querySelectorAll('.route-edit')];
    const routes = rows.map(readRouteRow);
    const total = routeWeight(routes.filter((route) => route.enabled));
    for (const [i, route] of routes.entries()) {
      rows[i].querySelector('.route-config-share').textContent = route.enabled && total > 0
        ? `同组配置比例 ${routeShare(route.weight / total)}` : '';
    }
    return { name: routeGroupName(index), routes };
  });
  const scenarioSelect = $('#route-scenario');
  const sourceOptions = $('#route-source-scenarios');
  const selected = scenarioSelect.value;
  const sourceIDs = new Set(groups.flatMap(({ routes }) => routes.filter((route) => route.enabled).map((route) => route.provider_id)));
  sourceOptions.replaceChildren(...state.providers.filter((provider) =>
    sourceIDs.has(provider.id) && provider.enabled && provider.health.state !== 'key_error',
  ).map((provider) => el('option', { value: `source:${provider.id}` }, `${providerOption(provider)}冷却`)));
  sourceOptions.hidden = !sourceOptions.children.length;
  scenarioSelect.value = [...scenarioSelect.options].some((option) => option.value === selected) ? selected : 'current';
  const scenario = scenarioSelect.value;
  const primarySources = new Set(groups[0]?.routes.filter((route) => route.enabled).map((route) => route.provider_id));
  for (const { routes } of groups) {
    for (const route of routes) {
      const provider = providers.get(route.provider_id);
      const localState = currentRoutes.get(JSON.stringify([route.provider_id, route.upstream_model]));
      const health = [provider?.health.state, localState];
      const simulatedCooling = scenario === 'all' || scenario === `source:${route.provider_id}` ||
        (scenario === 'primary' && primarySources.has(route.provider_id));
      if (!modelEnabled || !route.enabled) route.state = 'disabled';
      else if (!provider) route.state = 'provider_missing';
      else if (!provider.enabled) route.state = 'provider_disabled';
      else if (health.includes('key_error')) route.state = 'key_error';
      else if (simulatedCooling || health.includes('cooling')) route.state = 'cooling';
      else if (health.includes('probing')) route.state = 'probing';
      else if (health.includes('probe_ready')) route.state = 'probe_ready';
      else route.state = 'ready';
    }
  }
  const result = $('#route-preview-result');
  if (!modelEnabled) {
    result.replaceChildren(el('p', { class: 'field-hint' }, '模型停用后暂停路由。'));
    return;
  }
  if (groups.some(({ routes }) => routes.some((route) => route.enabled && !route.upstream_model))) {
    result.replaceChildren(el('p', { class: 'field-hint' }, '填写启用路由的来源侧模型名后即可预览。'));
    return;
  }
  if (groups.some(({ routes }) => routes.some((route) => route.enabled && !Number.isFinite(route.weight)))) {
    result.replaceChildren(el('p', { class: 'field-hint warn' }, '请使用 1 到 1000 的整数作为权重。'));
    return;
  }
  const candidates = candidateGroups(groups);
  const first = candidates[0]?.routes || [];
  const total = routeWeight(first);
  const order = candidates.map((group) => group.name).join(' → ');
  result.replaceChildren(
    el('p', { class: 'field-hint' }, order ? `候选组顺序 ${order}` : '当前没有可尝试的路由。'),
    el('ul', { class: 'route-preview-list' }, groups.flatMap(({ name, routes }) => routes.filter((route) => route.enabled).map((route) => {
      const label = `${name} · ${providerLabel(route.provider_id)} → ${route.upstream_model}`;
      const share = first.includes(route) ? route.weight / total : null;
      const status = share !== null
        ? `首选 ${routeShare(share)}`
        : routeEligible(route) ? '仅在失败后尝试' : routeState[route.state];
      return el('li', {},
        el('span', { class: 'route-preview-name' }, label),
        share !== null ? el('progress', { max: 1, value: share, 'aria-hidden': 'true' }) : null,
        el('span', { class: 'route-preview-share' }, status + (route.state === 'probe_ready' ? ' · 待试探' : '')),
      );
    }))),
  );
}

let editingModel = null;

function editModel(m, { copy = false } = {}) {
  if (!state.providers.length) { toast('先新增至少一个来源'); return; }
  editingModel = m && !copy ? m : null;
  const form = $('#model-form');
  const f = form.elements;
  form.reset();
  f.name.value = m && !copy ? m.name : '';
  f.name.readOnly = Boolean(editingModel);
  f.kind.value = m ? m.kind : 'chat';
  f.dimensions.value = m && m.dimensions ? String(m.dimensions) : '';
  f.enabled.checked = m ? m.enabled : true;
  f.note.value = m ? m.note : '';
  $('#model-title').textContent = copy ? '复制模型' : m ? '编辑模型 ' + m.name : '新增模型';
  $('#model-desc').textContent = copy
    ? `复制自 ${m.name}，路由已按原模型填好；给新模型起一个名称再保存。`
    : m ? '路由整体保存；改用途或向量维度会清理这个模型的嵌入缓存。'
        : '对外模型是客户端请求时使用的名字，路由决定请求发到哪个来源。';
  $('#route-rows').replaceChildren();
  const routes = m?.routes.length ? m.routes : [{ priority: 0 }];
  const groups = new Map(routeGroups(routes).map(([priority]) => [priority, addRouteGroup(priority)]));
  for (const route of routes) addRouteRow(route, groups.get(route.priority));
  updateRouteControls();
  checkModelName();
  clearError('model-error');
  $('#model-dialog').showModal();
  refresh();
  markClean(form);
  (editingModel ? f.kind : f.name).focus();
}

// checkModelName 在新增时提前说明同名会冲突，避免填完路由才发现保存被拒绝。
function checkModelName() {
  const hint = $('#model-name-hint');
  hint.classList.remove('warn');
  if (editingModel) {
    hint.textContent = '保存后不能改名；客户端请求里的 model 就是这个名字';
    return;
  }
  const name = $('#model-form').elements.name.value.trim();
  if (name && state.models.some((m) => m.name === name)) {
    hint.textContent = '已有同名模型，不能再用这个名称新增；要修改它请关闭弹窗，在列表里点“编辑”。';
    hint.classList.add('warn');
    return;
  }
  hint.textContent = '客户端请求里的 model，例如 zhixin-chat；可用字母、数字与 . _ : -';
}

$('#model-form').elements.name.addEventListener('input', checkModelName);

$('#model-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const form = event.target;
  const f = form.elements;
  const name = f.name.value.trim();
  const kind = f.kind.value;
  const rows = [...document.querySelectorAll('#route-rows .route-edit')].sort((a, b) => a.dataset.position - b.dataset.position);
  if (!rows.length) {
    showError('model-error', '至少添加一条路由。', $('#add-route'));
    return;
  }
  const routes = [];
  for (const row of rows) {
    const route = readRouteRow(row);
    if (!route.upstream_model) {
      showError('model-error', '请填写每一条路由的来源侧模型名。', row.querySelector('[name="upstream_model"]'));
      return;
    }
    if (kind === 'embedding') route.max_batch = Number(row.querySelector('[name="max_batch"]').value || 0);
    routes.push(route);
  }
  const seen = new Set();
  for (const route of routes) {
    const key = route.provider_id + '\u0000' + route.upstream_model;
    if (seen.has(key)) {
      showError('model-error', `来源 ${providerLabel(route.provider_id)} 与模型 ${route.upstream_model} 出现了重复路由。`);
      return;
    }
    seen.add(key);
  }
  if (!editingModel && state.models.some((m) => m.name === name)) {
    checkModelName();
    showError('model-error', `已存在同名模型 ${name}，不能再用这个名称新增；要修改它请关闭弹窗，在列表里点“编辑”。`, f.name);
    return;
  }
  const body = { kind, enabled: f.enabled.checked, note: f.note.value.trim(), routes };
  if (kind === 'embedding' && f.dimensions.value) body.dimensions = Number(f.dimensions.value);
  const editing = editingModel;
  if (!editing) body.name = name;
  await runSave($('#model-save'), async () => {
    try {
      await api(editing ? 'PUT' : 'POST', editing ? '/models/' + encodeURIComponent(name) : '/models', body);
    } catch (err) {
      if (err.data?.code === 'conflict') {
        await refresh();
        checkModelName();
        throw new Error(`已存在同名模型 ${name}；要修改它请关闭弹窗，在列表里点“编辑”，或换一个名称。`);
      }
      if (err.data?.code === 'not_found') {
        await refresh();
        throw new Error('这个模型已经不存在，可能刚被删除；列表已刷新。');
      }
      throw err;
    }
    $('#model-dialog').close();
    toast(editing ? '已保存，路由立即生效' : `已新增模型 ${name}`);
    refresh();
  }, 'model-error');
});

async function deleteModel(m) {
  const ok = await askConfirm({
    title: '删除这个模型？',
    message: `删除 ${m.name} 之后，客户端再请求这个名字会得到 model_not_allowed，相关的路由与嵌入缓存也会一并清理。`,
    ok: '删除',
    danger: true,
  });
  if (!ok) return;
  try {
    await api('DELETE', '/models/' + encodeURIComponent(m.name));
    toast('已删除模型 ' + m.name);
    refresh();
  } catch (err) { toast(err.message); }
}

async function testModel(m, route) {
  const title = route ? `探测 ${m.name} · ${route.provider_id} / ${route.upstream_model}` : `测试模型 ${m.name}`;
  const query = route ? '?' + new URLSearchParams({ provider_id: route.provider_id, upstream_model: route.upstream_model }) : '';
  const signal = beginProbe(title);
  try {
    const r = await api('POST', '/models/' + encodeURIComponent(m.name) + '/test' + query, null, signal);
    if (signal.aborted) return;
    const attempts = r.attempts || [];
    showProbe(title,
      el('p', {}, el('span', { class: r.ok ? 'ok' : 'bad' }, r.ok ? '可用' : '不可用'),
        `　耗时 ${r.latency_ms} ms`, r.status ? `　HTTP ${r.status}` : ''),
      attempts.length ? el('ol', { class: 'probe-attempts', 'aria-label': '实际尝试顺序' }, attempts.map((attempt) =>
        el('li', {},
          el('span', { class: 'mono' }, `${attempt.provider_id} → ${attempt.upstream_model}`),
          el('span', { class: attempt.ok ? 'ok' : 'bad' }, attempt.ok ? '成功' : attempt.error || '失败'),
          attempt.status && attempt.error !== `HTTP ${attempt.status}` ? el('span', { class: 'sub' }, `HTTP ${attempt.status}`) : null,
          attempt.recovery_probe ? el('span', { class: 'sub' }, '恢复试探') : null,
        ))) : null,
      r.dimensions ? el('p', {}, `返回向量 ${r.dimensions} 维` + (m.dimensions && m.dimensions !== r.dimensions ? `，与配置的 ${m.dimensions} 维不一致` : '')) : null,
      r.error && r.error !== attempts.at(-1)?.error ? el('p', {}, r.error) : null,
    );
    refresh();
  } catch (err) {
    if (!signal.aborted) showProbe(title, el('p', { class: 'bad' }, err.message));
  }
}

let probeRequest;
function beginProbe(title) {
  probeRequest?.abort();
  probeRequest = new AbortController();
  showProbe(title, el('p', {}, '请求中…'));
  $('#probe').scrollIntoView({ block: 'nearest' });
  return probeRequest.signal;
}

function showProbe(title, ...nodes) {
  $('#probe-title').textContent = title;
  $('#probe-body').replaceChildren(...nodes.filter(Boolean));
  $('#probe').hidden = false;
}
function closeProbe() {
  probeRequest?.abort();
  $('#probe').hidden = true;
}
$('#probe-close').addEventListener('click', closeProbe);

// ---- 用量统计 ----
let usageRequest;
let usageFilters = {};
let usageDay = null;
const number = new Intl.NumberFormat('zh-CN');
const axisNumber = new Intl.NumberFormat('zh-CN', { notation: 'compact', maximumFractionDigits: 1 });
const percent = new Intl.NumberFormat('zh-CN', { style: 'percent', maximumFractionDigits: 1 });
const usagePart = () => ({
  attempts: 0, first_attempts: 0, failover_attempts: 0, successes: 0,
  truncated_attempts: 0, canceled_attempts: 0, tokens: 0, estimated_tokens: 0,
  input_tokens: 0, cached_tokens: 0,
  first_input_tokens: 0, first_cached_tokens: 0, failover_input_tokens: 0, failover_cached_tokens: 0,
  first_input_reports: 0, first_cached_reports: 0, failover_input_reports: 0, failover_cached_reports: 0,
});
function addUsage(total, part) {
  for (const field of Object.keys(total)) total[field] += part[field];
  return total;
}
function successRate(u) {
  return u.attempts ? percent.format(u.successes / u.attempts) : '—';
}

// cacheHitRate 是来源报告的输入里命中缓存的比例；没有输入量时不显示。嵌入没有
// 缓存语义，它的输入不参与这个比例，调用方只传对话那一份用量。
function cacheHitRate(u) {
  return u.input_tokens > 0 ? routeShare(u.cached_tokens / u.input_tokens) : '';
}

// cacheHitRateOf 是单独一栏的命中率：首次尝试与换路尝试分开算，用来判断换路之后
// 已经热起来的前缀有没有被保住。
function cacheHitRateOf(inputTokens, cachedTokens) {
  return inputTokens > 0 ? routeShare(cachedTokens / inputTokens) : '';
}

// cacheUnreported 是来源给了输入量却没有给 cached_tokens 的条数。这些尝试既不能
// 算命中也不能算零命中，单独列出来，否则缺报会被读成零命中。
function cacheUnreported(u) {
  return (u.first_input_reports - u.first_cached_reports) + (u.failover_input_reports - u.failover_cached_reports);
}

// cacheNotes 是卡片里那一行缓存说明：命中率、首次与换路的差别、缓存字段的上报
// 覆盖率与缺报条数。
function cacheNotes(u) {
  const hit = cacheHitRate(u);
  if (!hit) return '';
  const parts = [`输入缓存命中 ${hit}（${number.format(u.cached_tokens)}/${number.format(u.input_tokens)}）`];
  const first = cacheHitRateOf(u.first_input_tokens, u.first_cached_tokens);
  const failover = cacheHitRateOf(u.failover_input_tokens, u.failover_cached_tokens);
  if (first) parts.push(`首次 ${first}`);
  if (failover) parts.push(`换路 ${failover}`);
  const reports = u.first_input_reports + u.failover_input_reports;
  const reported = u.first_cached_reports + u.failover_cached_reports;
  if (reports > 0) parts.push(`缓存字段上报 ${percent.format(reported / reports)}`);
  const unreported = reports - reported;
  if (unreported > 0) parts.push(`缺报 ${number.format(unreported)} 条`);
  return parts.join(' · ');
}

// cacheRowNote 是表格行里的短版本，只放这一行用得上的数字。
function cacheRowNote(u) {
  const hit = cacheHitRate(u);
  if (!hit) return '';
  const parts = [`输入 ${number.format(u.input_tokens)}`, `命中 ${hit}`];
  const first = cacheHitRateOf(u.first_input_tokens, u.first_cached_tokens);
  const failover = cacheHitRateOf(u.failover_input_tokens, u.failover_cached_tokens);
  if (first && failover) parts.push(`首次 ${first} · 换路 ${failover}`);
  const unreported = cacheUnreported(u);
  if (unreported > 0) parts.push(`缺报 ${number.format(unreported)} 条`);
  return parts.join(' · ');
}

$('#usage-days').addEventListener('change', loadUsage);
$('#refresh-usage').addEventListener('click', loadUsage);
$('#usage-kind').addEventListener('change', () => {
  usageFilters.kind = $('#usage-kind').value;
  renderUsage();
});
for (const field of ['model', 'provider', 'upstream']) {
  $('#usage-' + field).addEventListener('change', (event) => {
    usageFilters[field] = event.target.value;
    if (field !== 'upstream') usageFilters.upstream = '';
    renderUsage();
  });
}
$('#clear-usage-filters').addEventListener('click', () => {
  usageFilters = {};
  renderUsage();
  $('#usage-kind').focus();
});
$('#usage-metric').addEventListener('change', renderUsage);
$('#usage-group').addEventListener('change', renderUsage);
$('#clear-usage-day').addEventListener('click', () => {
  usageDay = null;
  renderUsage();
  $('#usage-group').focus();
});

function openRouteUsage(model, route) {
  usageFilters = { kind: model.kind, model: model.name, provider: route.provider_id, upstream: route.upstream_model };
  usageDay = null;
  $('#usage-group').value = 'route';
  $('#nav-usage').focus();
  selectTab($('#nav-usage'));
}

function setUsageOptions(field, items, placeholder) {
  const select = $('#usage-' + field);
  const selected = usageFilters[field] || '';
  const values = [...new Set([...items, selected])].filter(Boolean).sort((a, b) => a.localeCompare(b));
  const options = [el('option', { value: '' }, placeholder),
    ...values.map((value) => el('option', { value }, value))];
  select.replaceChildren(...options);
  select.value = selected;
}

function renderUsageFilters(routes) {
  const { kind = 'all', model, provider, upstream } = usageFilters;
  $('#usage-kind').value = kind;
  setUsageOptions('model', [...state.models.map((m) => m.name), ...routes.map((r) => r.model)], '全部模型');
  setUsageOptions('provider', [...state.providers.map((p) => p.id), ...routes.map((r) => r.provider_id)], '全部来源');
  $('#usage-upstream-field').hidden = !model || !provider;
  if (model && provider) {
    const configured = state.models.find((m) => m.name === model)?.routes ?? [];
    const upstreams = [...configured.filter((r) => r.provider_id === provider),
      ...routes.filter((r) => r.model === model && r.provider_id === provider)];
    setUsageOptions('upstream', upstreams.map((r) => r.upstream_model), '全部来源侧模型');
  }
  $('#clear-usage-filters').hidden = kind === 'all' && !model && !provider && !upstream;
}

async function loadUsage() {
  usageRequest?.abort();
  const current = new AbortController();
  usageRequest = current;
  state.usage = null;
  const status = $('#usage-status');
  status.textContent = '正在读取用量…';
  status.hidden = false;
  $('#usage-period').textContent = '';
  $('#usage-report').hidden = true;
  try {
    const report = await api('GET', '/usage?days=' + $('#usage-days').value, null, current.signal);
    if (current.signal.aborted) return;
    state.usage = report;
    renderUsage();
    status.hidden = true;
    $('#usage-report').hidden = false;
    await loadKeyUsage(current.signal);
  } catch (err) {
    if (!current.signal.aborted) {
      status.textContent = '读取用量失败。' + err.message;
      // 新区间没有读成功，按密钥的表不能继续留着上一个区间的数字。
      resetKeyUsage('读取用量失败，密钥用量未更新。');
    }
  }
}

// resetKeyUsage 清空按密钥的表并停在提示文案上。读取用量失败或换区间时都要调用，
// 旧区间的表留着会被当成新区间的结果。
function resetKeyUsage(message) {
  state.keyUsage = null;
  $('#key-usage-rows').replaceChildren();
  const status = $('#key-usage-status');
  status.textContent = message;
  status.hidden = false;
}

// 按密钥的对账视图单独读一次：它比路由汇总多一层账号维度，失败时只关掉这张
// 表，上面的路由用量照常显示。
async function loadKeyUsage(signal) {
  resetKeyUsage('正在读取密钥用量…');
  try {
    const report = await api('GET', '/key-usage?days=' + $('#usage-days').value, null, signal);
    if (signal?.aborted) return;
    state.keyUsage = report;
    renderKeyUsage();
  } catch (err) {
    if (!signal?.aborted) resetKeyUsage('读取密钥用量失败。' + err.message);
  }
}

function renderUsage() {
  const report = state.usage;
  if (!report) return;
  renderUsageFilters(report.routes);
  const { kind = 'all', model, provider, upstream } = usageFilters;
  const kinds = kind === 'all' ? kindList : [kind];
  const routes = report.routes.filter((r) =>
    kinds.includes(r.kind) && (!model || r.model === model) &&
    (!provider || r.provider_id === provider) && (!upstream || r.upstream_model === upstream));
  const days = report.daily.map(({ day }) => ({ day, chat: usagePart(), embedding: usagePart() }));
  const byDate = new Map(days.map((day) => [day.day, day]));
  for (const route of routes) {
    for (const [date, usage] of Object.entries(route.daily)) addUsage(byDate.get(date)[route.kind], usage);
  }
  if (!byDate.has(usageDay)) usageDay = null;
  const totals = usagePart();
  for (const day of days) {
    for (const kind of kinds) addUsage(totals, day[kind]);
  }
  // 缓存命中只看对话：嵌入的输入没有缓存语义，混进分母会把比例压下去，“全部用途”
  // 与按用途分别看因此对不上。
  const chatTotals = usagePart();
  for (const day of days) {
    if (kinds.includes('chat')) addUsage(chatTotals, day.chat);
  }
  $('#usage-period').textContent = `${days[0].day} 至 ${days.at(-1).day} · ${report.timezone}`;
  $('#usage-tokens').textContent = number.format(totals.tokens);
  $('#usage-estimate').textContent = `含估算 ${number.format(totals.estimated_tokens)}`;
  $('#usage-cache').textContent = cacheNotes(chatTotals);
  $('#usage-attempts').textContent = number.format(totals.attempts);
  $('#usage-attempt-detail').textContent = `${number.format(totals.first_attempts)} 次首次 · ${number.format(totals.failover_attempts)} 次故障切换`;
  $('#usage-unsuccessful').textContent = `${number.format(totals.attempts - totals.successes)} 次未成功`;
  $('#usage-success-rate').textContent = successRate(totals);
  $('#usage-successes').textContent = `${number.format(totals.successes)} 次成功`;
  const selectUsageDay = (date) => updateUsageDay(date, routes, byDate);
  renderUsageChart(days, kinds, totals.attempts > 0, selectUsageDay);
  selectUsageDay(usageDay);
}

function renderUsageChart(days, kinds, hasAttempts, selectUsageDay) {
  for (const kind of kindList) $('#legend-' + kind).hidden = !kinds.includes(kind);
  $('#usage-legend').hidden = !hasAttempts;
  $('#usage-chart-empty').hidden = hasAttempts;
  $('#usage-chart-wrap').hidden = !hasAttempts;
  const chart = $('#usage-chart');
  chart.replaceChildren();
  if (!hasAttempts) return;

  const metric = $('#usage-metric');
  const amount = (u) => metric.value === 'unsuccessful' ? u.attempts - u.successes : u[metric.value];
  const values = days.map((day) => kinds.reduce((sum, kind) => sum + amount(day[kind]), 0));
  const peak = Math.max(...values, 1);
  const step = 10 ** Math.floor(Math.log10(peak / 4));
  const ceiling = Math.max(4, 4 * step * Math.ceil(peak / (4 * step)));
  $('#usage-scale').replaceChildren(...[ceiling, ceiling / 2, 0].map((n) => el('span', {}, axisNumber.format(n))));

  for (const [index, day] of days.entries()) {
    const bars = el('span', { class: 'usage-bar-track', 'aria-hidden': 'true' });
    for (const kind of kinds) {
      const bar = el('span', { class: kind + '-color' });
      bar.style.height = `${(amount(day[kind]) / ceiling) * 100}%`;
      bars.append(bar);
    }
    const label = days.length <= 7 || index % 5 === 0 || index === days.length - 1 ? day.day.slice(5) : '';
    const labelText = `${day.day}，${metric.selectedOptions[0].textContent} ${number.format(values[index])}`;
    chart.append(el('button', { type: 'button', class: 'usage-day', title: labelText, 'aria-label': labelText, 'data-day': day.day,
      'aria-pressed': 'false', onclick: () => selectUsageDay(usageDay === day.day ? null : day.day) },
      bars, el('span', { class: 'usage-day-label', 'aria-hidden': 'true' }, label)));
  }
}

function updateUsageDay(date, routes, byDate) {
  usageDay = date;
  for (const button of $('#usage-chart').children) button.setAttribute('aria-pressed', String(button.dataset.day === date));
  $('#usage-table-scope').textContent = date || '整个区间';
  $('#clear-usage-day').hidden = !date;
  const day = byDate.get(date);
  const detail = $('#usage-day-detail');
  const total = day ? addUsage(addUsage(usagePart(), day.chat), day.embedding) : null;
  detail.textContent = total
    ? `${date} · ${number.format(total.tokens)} Token（含估算 ${number.format(total.estimated_tokens)}） · ${number.format(total.attempts)} 次尝试（${number.format(total.first_attempts)} 首次，${number.format(total.failover_attempts)} 故障切换） · ${number.format(total.attempts - total.successes)} 次未成功${cacheHitRate(total) ? ` · 输入缓存命中 ${cacheHitRate(total)}` : ''}`
    : ($('#usage-chart-wrap').hidden ? '' : '选择日期查看当天明细。');
  renderUsageTable(routes, date);
  renderKeyUsage();
}

function renderUsageTable(routes, date) {
  const group = $('#usage-group').value;
  const rows = new Map();
  for (const r of routes) {
    const usage = date ? r.daily[date] : r.usage;
    if (!usage) continue;
    const label = group === 'provider' ? r.provider_id : r.model;
    const sub = group === 'route' ? `${r.provider_id} → ${r.upstream_model}` : '';
    const key = JSON.stringify([label, r.kind, sub]);
    if (!rows.has(key)) rows.set(key, { label, sub, kind: r.kind, usage: usagePart() });
    addUsage(rows.get(key).usage, usage);
  }
  const target = $('#usage-rows');
  target.replaceChildren();
  if (!rows.size) {
    target.append(el('tr', {}, el('td', { colspan: 9, class: 'empty' }, '没有符合条件的用量记录。')));
    return;
  }
  const sorted = [...rows.values()].sort((a, b) => b.usage.tokens - a.usage.tokens || b.usage.attempts - a.usage.attempts || a.label.localeCompare(b.label));
  for (const { label, sub, kind, usage: u } of sorted) {
    const incomplete = [
      u.truncated_attempts ? `截断 ${number.format(u.truncated_attempts)}` : '',
      u.canceled_attempts ? `取消 ${number.format(u.canceled_attempts)}` : '',
    ].filter(Boolean).join(' · ');
    target.append(el('tr', {}, el('td', {}, el('span', { class: 'mono' }, label), sub ? el('div', { class: 'sub mono' }, sub) : null),
      el('td', { class: 'nowrap' }, kindName[kind]),
      el('td', { class: 'numeric' }, number.format(u.tokens),
        kind === 'chat' && cacheRowNote(u)
          ? el('div', { class: 'sub' }, cacheRowNote(u))
          : null),
      [u.estimated_tokens, u.attempts, u.first_attempts, u.failover_attempts]
        .map((n) => el('td', { class: 'numeric' }, number.format(n))),
      el('td', { class: 'numeric' }, number.format(u.attempts - u.successes), incomplete ? el('div', { class: 'sub' }, incomplete) : null),
      el('td', { class: 'numeric' }, successRate(u))));
  }
}

// ---- 按密钥计费 ----
// 金额只由对话的计费 token 折算：嵌入不参与积分核销，折进金额会让人以为嵌入也
// 能用积分支付。趋势条按整个区间的峰值缩放，横向比较同一张表里的密钥。核销按
// 向上取整折积分，这里同样向上取整，数字才对得上；没有扣当天的免费额度，只是
// 对账参考，不代表实际核销。
function keyUsagePoints(tokens, perPoint) {
  if (!perPoint || perPoint <= 0) return '—';
  return '≈' + number.format(Math.ceil(tokens / perPoint));
}

// keyStatus 说明这把密钥现在还能不能用。api_key 行被每日清理删除之后既没有名字，
// 撤销状态也是 false，只看这两项会把它显示成“在用”。
function keyStatus(key) {
  if (!key.key_present) return '已清理';
  return key.revoked ? '已撤销' : '在用';
}

function shortAccount(id) {
  return id.length <= 12 ? id : id.slice(0, 8) + '…';
}

function renderKeyUsage() {
  const report = state.keyUsage;
  if (!report) return;
  const body = $('#key-usage-rows');
  body.replaceChildren();
  const scope = usageDay;
  $('#key-usage-scope').textContent = scope ? scope + ' · 当天' : '整个区间';
  const perPoint = report.tokens_per_point || 0;
  $('#key-usage-ratio').textContent = perPoint > 0 ? `1 积分 = ${number.format(perPoint)} 计费 token` : '未配置积分比例';
  const dates = state.usage
    ? state.usage.daily.map((day) => day.day)
    : [...new Set(report.keys.flatMap((key) => Object.keys(key.daily)))].sort();
  const amount = (usage) => (usage ? usage.chat.tokens + usage.embedding.tokens : 0);
  const peak = report.keys.reduce(
    (max, key) => dates.reduce((value, date) => Math.max(value, amount(key.daily[date])), max), 1);

  const shown = [];
  for (const key of report.keys) {
    const usage = scope ? key.daily[scope] : { chat: key.chat, embedding: key.embedding };
    if (!usage) continue;
    const tokenRow = key.key_id === '';
    const name = tokenRow ? '访问令牌'
      : (key.key_present ? (key.name || '未命名密钥') : '已清理的密钥');
    const sub = tokenRow ? '客户端调用' : key.prefix || key.key_id;
    const spark = el('span', { class: 'key-spark' });
    for (const date of dates) {
      const value = amount(key.daily[date]);
      const bar = el('span', { class: value ? 'key-spark-bar' : 'key-spark-bar key-spark-empty',
        title: `${date}：${number.format(value)} Token` });
      bar.style.height = value ? `${Math.max(6, (value / peak) * 100)}%` : '2px';
      spark.append(bar);
    }
    shown.push(el('tr', {},
      el('td', {}, el('span', { class: 'mono' }, name), el('div', { class: 'sub mono' }, sub)),
      el('td', { class: 'mono', title: key.user_id }, shortAccount(key.user_id)),
      el('td', { class: 'numeric' }, number.format(usage.chat.tokens)),
      el('td', { class: 'numeric' }, keyUsagePoints(usage.chat.tokens, perPoint)),
      el('td', { class: 'numeric' }, number.format(usage.embedding.tokens)),
      el('td', { class: 'numeric' }, number.format(usage.chat.reserved_tokens + usage.embedding.reserved_tokens)),
      el('td', { class: 'numeric' }, spark),
      el('td', { class: 'nowrap' }, key.last_used_at ? moment(key.last_used_at) : '—'),
      el('td', {}, tokenRow ? '—' : keyStatus(key))));
  }
  const status = $('#key-usage-status');
  for (const row of shown) body.append(row);
  status.textContent = shown.length ? '' : '所选范围内没有密钥调用记录。';
  status.hidden = shown.length > 0;
}

// ---- 留存 ----
// 只读视图：匿名安装既能看每日活跃，也能看按首次出现日分组的队列留存；登录
// 账号只有每日活跃。观察期还没走完的批次不给留存率，否则最后这几天的“还没
// 来得及回来”会被读成流失。
let retentionRequest;
const DAY_MS = 86400000;

// retentionDays 算两个自然日之间相差几天，按 UTC 零点解析，不受本地时区影响。
function retentionDays(from, to) {
  return Math.round((Date.parse(to + 'T00:00:00Z') - Date.parse(from + 'T00:00:00Z')) / DAY_MS);
}

const retentionRate = (part, total) => (total > 0 ? percent.format(part / total) : '—');

$('#retention-days').addEventListener('change', loadRetention);
$('#refresh-retention').addEventListener('click', loadRetention);

async function loadRetention() {
  retentionRequest?.abort();
  const current = new AbortController();
  retentionRequest = current;
  state.retention = null;
  const status = $('#retention-status');
  status.textContent = '正在读取留存…';
  status.hidden = false;
  $('#retention-report').hidden = true;
  try {
    const report = await api('GET', '/retention?days=' + $('#retention-days').value, null, current.signal);
    if (current.signal.aborted) return;
    state.retention = report;
    renderRetention();
    status.hidden = true;
    $('#retention-report').hidden = false;
  } catch (err) {
    if (!current.signal.aborted) status.textContent = '读取留存失败。' + err.message;
  }
}

function renderRetention() {
  const report = state.retention;
  if (!report) return;
  const today = report.daily.length ? report.daily.at(-1).day : '';
  $('#retention-period').textContent = report.daily.length
    ? `${report.daily[0].day} 至 ${today} · ${report.timezone}`
    : `${report.timezone}`;
  renderRetentionCohorts(report.cohorts, today);
  renderRetentionDaily(report.daily);
}

function renderRetentionCohorts(cohorts, today) {
  const body = $('#retention-cohort-rows');
  body.replaceChildren();
  $('#retention-cohort-empty').hidden = cohorts.length > 0;
  let installs = 0;
  let weekInstalls = 0;
  let weekReturned = 0;
  let monthInstalls = 0;
  let monthReturned = 0;
  let pending = false;
  for (const cohort of cohorts) {
    installs += cohort.installs;
    const age = retentionDays(cohort.first_day, today);
    const weekClosed = age >= 7;
    const monthClosed = age >= 28;
    if (weekClosed) {
      weekInstalls += cohort.installs;
      weekReturned += cohort.returned_7d;
    }
    if (monthClosed) {
      monthInstalls += cohort.installs;
      monthReturned += cohort.returned_28d;
    }
    if (!monthClosed) pending = true;
    body.append(el('tr', {},
      el('td', { class: 'mono nowrap' }, cohort.first_day),
      el('td', { class: 'numeric' }, number.format(cohort.installs)),
      el('td', { class: 'numeric' }, number.format(cohort.returned_7d)),
      el('td', { class: 'numeric' }, weekClosed
        ? retentionRate(cohort.returned_7d, cohort.installs)
        : el('span', { class: 'sub' }, '观察未满')),
      el('td', { class: 'numeric' }, number.format(cohort.returned_28d)),
      el('td', { class: 'numeric' }, monthClosed
        ? retentionRate(cohort.returned_28d, cohort.installs)
        : el('span', { class: 'sub' }, '观察未满'))));
  }
  const parts = [];
  if (cohorts.length) parts.push(`${number.format(installs)} 台新安装`);
  if (weekInstalls) parts.push(`7 日留存 ${retentionRate(weekReturned, weekInstalls)}`);
  if (monthInstalls) parts.push(`28 日留存 ${retentionRate(monthReturned, monthInstalls)}`);
  $('#retention-summary').textContent = parts.length
    ? parts.join(' · ') + (pending ? '（只汇总观察期已满的批次）' : '')
    : '';
}

function renderRetentionDaily(daily) {
  const body = $('#retention-daily-rows');
  body.replaceChildren();
  for (const day of [...daily].reverse()) {
    body.append(el('tr', {},
      el('td', { class: 'mono nowrap' }, day.day),
      el('td', { class: 'numeric' }, number.format(day.installs)),
      el('td', { class: 'numeric' }, number.format(day.users))));
  }
}

// ---- 账号管理 ----
// 账号页只调用 /admin/v1/accounts 下的接口。列表带额度覆盖值与生效值，单独读取
// 一个账号时再取今日已结算用量；注销与恢复默认都要求二次确认，删除请求体里
// 再提交一次账号编号，编号看错时不会误删另一个账号。
let accountRequest;
let accountQuotaAccount = null;
let accountDeleteAccount = null;
let accountSearchTimer;

const accountLimitText = (value) => (value > 0 ? number.format(value) : '不限');

function accountIdentities(account) {
  return account.identities.map((identity) => identity.identifier).filter(Boolean);
}

function accountLabel(account) {
  const identifiers = accountIdentities(account);
  return identifiers.length ? identifiers.join('、') : account.id;
}

function accountVerified(account) {
  return account.identities.some((identity) => identity.verified);
}

function accountRow(account) {
  const quota = account.quota;
  const applied = quota.daily_tokens_override != null || quota.embedding_daily_tokens_override != null || quota.note;
  const quotaText = (label, effective, override) => el('div', {},
    `${label} ${accountLimitText(effective)}`,
    override != null ? el('span', { class: 'quota-tag' }, '已调整') : el('span', { class: 'quota-tag default' }, '默认'));
  return el('tr', {},
    el('td', { class: 'account-cell', 'data-label': '账号' },
      el('span', { class: 'account-email' }, account.identities.length ? accountLabel(account) : '（没有登录方式）'),
      el('span', { class: 'account-id mono', title: account.id }, account.id)),
    el('td', { 'data-label': '状态' },
      el('span', { class: 'badge ' + (accountVerified(account) ? 'ok' : 'muted') },
        accountVerified(account) ? '已验证' : '未验证')),
    el('td', { 'data-label': '注册时间' }, moment(account.created_at) || '—'),
    el('td', { class: 'account-quota', 'data-label': '每日额度' },
      quotaText('聊天', quota.daily_tokens, quota.daily_tokens_override),
      quotaText('嵌入', quota.embedding_daily_tokens, quota.embedding_daily_tokens_override),
      quota.note ? el('div', { class: 'sub' }, quota.note) : null),
    el('td', { class: 'ops', 'data-label': '操作' }, el('div', { class: 'row-actions' },
      el('button', { type: 'button', class: 'link', 'aria-label': `调整 ${account.id} 的额度`,
        onclick: () => openQuota(account) }, '额度'),
      el('button', { type: 'button', class: 'danger', 'aria-label': `注销 ${account.id}`,
        onclick: () => openAccountDelete(account) }, '注销'))));
}

function renderAccounts() {
  const body = $('#accounts');
  body.replaceChildren();
  const total = state.accountTotal;
  const shown = state.accounts.length;
  $('#account-summary').textContent = state.accountQuery
    ? `搜索“${state.accountQuery}”，匹配 ${number.format(total)} 个账号`
    : `共 ${number.format(total)} 个账号`;
  $('#account-filter-count').textContent = shown ? `当前显示 ${number.format(shown)} 个` : '';
  const start = shown ? state.accountOffset + 1 : 0;
  const end = state.accountOffset + shown;
  $('#account-page').textContent = total
    ? `第 ${number.format(start)}–${number.format(end)} 个，共 ${number.format(total)} 个`
    : '';
  $('#account-prev').disabled = state.accountOffset === 0;
  $('#account-next').disabled = end >= total;
  if (!shown) {
    body.append(el('tr', {}, el('td', { class: 'empty', colspan: '5' },
      state.accountQuery ? '没有匹配的账号。' : '还没有账号。')));
    return;
  }
  for (const account of state.accounts) body.append(accountRow(account));
}

async function loadAccounts() {
  accountRequest?.abort();
  const controller = new AbortController();
  accountRequest = controller;
  const status = $('#account-status');
  status.textContent = '正在读取账号…';
  status.hidden = false;
  const params = new URLSearchParams({
    limit: String(state.accountLimit), offset: String(state.accountOffset),
  });
  if (state.accountQuery) params.set('query', state.accountQuery);
  try {
    const data = await api('GET', '/accounts?' + params, null, controller.signal);
    if (accountRequest !== controller) return;
    state.accounts = data.data || [];
    state.accountTotal = data.total || 0;
    renderAccounts();
    status.hidden = true;
  } catch (err) {
    if (err.name === 'AbortError') return;
    status.textContent = err.message;
    status.hidden = false;
  } finally {
    if (accountRequest === controller) accountRequest = null;
  }
}

function setAccountQuery(value) {
  const query = value.trim();
  if (query === state.accountQuery) return;
  state.accountQuery = query;
  state.accountOffset = 0;
  loadAccounts();
}

$('#account-search').addEventListener('input', (event) => {
  clearTimeout(accountSearchTimer);
  accountSearchTimer = setTimeout(() => setAccountQuery(event.target.value), 250);
});
$('#account-search').addEventListener('keydown', (event) => {
  if (event.key !== 'Enter') return;
  event.preventDefault();
  clearTimeout(accountSearchTimer);
  setAccountQuery(event.target.value);
});
$('#refresh-accounts').addEventListener('click', () => loadAccounts());
$('#account-prev').addEventListener('click', () => {
  if (state.accountOffset === 0) return;
  state.accountOffset = Math.max(0, state.accountOffset - state.accountLimit);
  loadAccounts();
});
$('#account-next').addEventListener('click', () => {
  if (state.accountOffset + state.accounts.length >= state.accountTotal) return;
  state.accountOffset += state.accountLimit;
  loadAccounts();
});

// openQuota 先读单个账号，取得今天的已结算用量再打开弹窗；列表里的额度可能
// 已经被另一次保存改过，打开时以服务端返回的覆盖值为准。
async function openQuota(account) {
  try {
    const detail = await api('GET', '/accounts/' + encodeURIComponent(account.id));
    accountQuotaAccount = detail;
    const form = $('#quota-form');
    form.reset();
    form.elements.daily_tokens.value = detail.quota.daily_tokens_override ?? '';
    form.elements.embedding_daily_tokens.value = detail.quota.embedding_daily_tokens_override ?? '';
    form.elements.note.value = detail.quota.note || '';
    $('#quota-account').textContent = `${accountLabel(detail)}（${detail.id}）`;
    $('#quota-chat-used').textContent = `${number.format(detail.usage?.chat_tokens || 0)} Token`;
    $('#quota-embedding-used').textContent = `${number.format(detail.usage?.embedding_tokens || 0)} Token`;
    $('#quota-chat-default').textContent = accountLimitText(detail.quota.default_daily_tokens);
    $('#quota-embedding-default').textContent = accountLimitText(detail.quota.default_embedding_daily_tokens);
    $('#quota-updated').textContent = detail.quota.updated_at ? '最近保存 ' + moment(detail.quota.updated_at) : '';
    $('#quota-reset').disabled = detail.quota.daily_tokens_override == null &&
      detail.quota.embedding_daily_tokens_override == null && !detail.quota.note;
    clearError('quota-error');
    markClean(form);
    $('#quota-dialog').showModal();
  } catch (err) {
    toast(err.message);
  }
}

function quotaInput(form, name) {
  const raw = form.elements[name].value.trim();
  if (!raw) return null;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 1) throw new Error('每日额度必须是大于 0 的整数，留空表示使用默认值。');
  return value;
}

$('#quota-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  if (!accountQuotaAccount) return;
  const form = event.currentTarget;
  let daily;
  let embedding;
  try {
    daily = quotaInput(form, 'daily_tokens');
    embedding = quotaInput(form, 'embedding_daily_tokens');
  } catch (err) {
    showError('quota-error', err.message);
    return;
  }
  const note = form.elements.note.value.trim();
  await runSave($('#quota-save'), async () => {
    const saved = await api('PUT', '/accounts/' + encodeURIComponent(accountQuotaAccount.id) + '/quota',
      { daily_tokens: daily, embedding_daily_tokens: embedding, note });
    const index = state.accounts.findIndex((item) => item.id === saved.id);
    if (index >= 0) state.accounts[index] = saved;
    renderAccounts();
    $('#quota-dialog').close();
    toast('额度已保存，下一次模型请求生效。');
  }, 'quota-error');
});

$('#quota-reset').addEventListener('click', async () => {
  if (!accountQuotaAccount) return;
  const ok = await askConfirm({
    title: '恢复默认额度？',
    message: `${accountLabel(accountQuotaAccount)} 的额度覆盖与备注将被清除，回到实例默认值。`,
    ok: '恢复默认',
  });
  if (!ok) return;
  try {
    await api('DELETE', '/accounts/' + encodeURIComponent(accountQuotaAccount.id) + '/quota');
    $('#quota-dialog').close();
    toast('已恢复默认额度。');
    await loadAccounts();
  } catch (err) {
    showError('quota-error', err.message);
  }
});

function openAccountDelete(account) {
  accountDeleteAccount = account;
  const form = $('#account-delete-form');
  form.reset();
  $('#account-delete-summary').textContent =
    `即将注销 ${accountLabel(account)}（${account.id}）。`;
  $('#account-delete-hint').textContent = `请输入 ${accountLabel(account)} 或 ${account.id}`;
  clearError('account-delete-error');
  markClean(form);
  $('#account-delete-dialog').showModal();
}

$('#account-delete-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  if (!accountDeleteAccount) return;
  const form = event.currentTarget;
  const typed = form.elements.confirm.value.trim();
  const accepted = [accountDeleteAccount.id, ...accountIdentities(accountDeleteAccount)];
  if (!accepted.some((value) => value.toLowerCase() === typed.toLowerCase())) {
    showError('account-delete-error', '输入的邮箱或账号编号与要注销的账号不一致。');
    return;
  }
  await runSave($('#account-delete-submit'), async () => {
    await api('DELETE', '/accounts/' + encodeURIComponent(accountDeleteAccount.id),
      { user_id: accountDeleteAccount.id });
    $('#account-delete-dialog').close();
    toast('账号已注销。');
    if (state.accounts.length === 1 && state.accountOffset > 0) {
      state.accountOffset = Math.max(0, state.accountOffset - state.accountLimit);
    }
    await loadAccounts();
  }, 'account-delete-error');
});

// ---- 反馈 ----
// 反馈页只调用 /admin/v1/feedback 下的接口。列表按提交时间倒序分页，正文显示
// 前三行；诊断摘要只在打开单条时读取，删除放在弹窗里并要求确认。
let feedbackRequest;
let feedbackDetail = null;
let feedbackSearchTimer;

function feedbackRow(item) {
  const meta = [item.app_version, item.platform].filter(Boolean).join(' · ');
  return el('tr', {},
    el('td', { 'data-label': '提交时间' }, moment(item.created_at) || '—',
      meta ? el('div', { class: 'feedback-meta' }, meta) : null,
      item.has_diagnostics ? el('span', { class: 'tag feedback-diagnostics-tag' }, '含诊断') : null),
    el('td', { 'data-label': '正文', class: 'feedback-body' }, el('div', { class: 'feedback-content' }, item.content)),
    el('td', { 'data-label': '联系邮箱' }, item.contact || '—'),
    el('td', { class: 'ops', 'data-label': '操作' }, el('div', { class: 'row-actions' },
      el('button', { type: 'button', class: 'link', 'aria-label': `查看反馈 ${item.id}`,
        onclick: () => openFeedback(item) }, '查看'))));
}

function renderFeedback() {
  const body = $('#feedback-rows');
  body.replaceChildren();
  const total = state.feedbackTotal;
  const shown = state.feedback.length;
  $('#feedback-summary').textContent = state.feedbackQuery
    ? `搜索“${state.feedbackQuery}”，匹配 ${number.format(total)} 条反馈`
    : `共 ${number.format(total)} 条反馈`;
  $('#feedback-filter-count').textContent = shown ? `当前显示 ${number.format(shown)} 条` : '';
  const start = shown ? state.feedbackOffset + 1 : 0;
  const end = state.feedbackOffset + shown;
  $('#feedback-page').textContent = total
    ? `第 ${number.format(start)}–${number.format(end)} 条，共 ${number.format(total)} 条`
    : '';
  $('#feedback-prev').disabled = state.feedbackOffset === 0;
  $('#feedback-next').disabled = end >= total;
  if (!shown) {
    body.append(el('tr', {}, el('td', { class: 'empty', colspan: '4' },
      state.feedbackQuery ? '没有匹配的反馈。' : '还没有反馈。')));
    return;
  }
  for (const item of state.feedback) body.append(feedbackRow(item));
}

async function loadFeedback() {
  feedbackRequest?.abort();
  const controller = new AbortController();
  feedbackRequest = controller;
  const status = $('#feedback-status');
  status.textContent = '正在读取反馈…';
  status.hidden = false;
  const params = new URLSearchParams({
    limit: String(state.feedbackLimit), offset: String(state.feedbackOffset),
  });
  if (state.feedbackQuery) params.set('query', state.feedbackQuery);
  try {
    const data = await api('GET', '/feedback?' + params, null, controller.signal);
    if (feedbackRequest !== controller) return;
    state.feedback = data.data || [];
    state.feedbackTotal = data.total || 0;
    renderFeedback();
    status.hidden = true;
  } catch (err) {
    if (err.name === 'AbortError') return;
    status.textContent = err.message;
    status.hidden = false;
  } finally {
    if (feedbackRequest === controller) feedbackRequest = null;
  }
}

function setFeedbackQuery(value) {
  const query = value.trim();
  if (query === state.feedbackQuery) return;
  state.feedbackQuery = query;
  state.feedbackOffset = 0;
  loadFeedback();
}

$('#feedback-search').addEventListener('input', (event) => {
  clearTimeout(feedbackSearchTimer);
  feedbackSearchTimer = setTimeout(() => setFeedbackQuery(event.target.value), 250);
});
$('#feedback-search').addEventListener('keydown', (event) => {
  if (event.key !== 'Enter') return;
  event.preventDefault();
  clearTimeout(feedbackSearchTimer);
  setFeedbackQuery(event.target.value);
});
$('#refresh-feedback').addEventListener('click', () => loadFeedback());
$('#feedback-prev').addEventListener('click', () => {
  if (state.feedbackOffset === 0) return;
  state.feedbackOffset = Math.max(0, state.feedbackOffset - state.feedbackLimit);
  loadFeedback();
});
$('#feedback-next').addEventListener('click', () => {
  if (state.feedbackOffset + state.feedback.length >= state.feedbackTotal) return;
  state.feedbackOffset += state.feedbackLimit;
  loadFeedback();
});

async function openFeedback(item) {
  try {
    const detail = await api('GET', '/feedback/' + encodeURIComponent(item.id));
    feedbackDetail = detail;
    $('#feedback-created').textContent = moment(detail.created_at) || '—';
    $('#feedback-version').textContent = detail.app_version || '—';
    $('#feedback-platform').textContent = detail.platform || '—';
    $('#feedback-contact').textContent = detail.contact || '（没有填写）';
    $('#feedback-id').textContent = detail.id;
    $('#feedback-content').textContent = detail.content;
    const diagnostics = detail.diagnostics || '';
    $('#feedback-diagnostics').textContent = diagnostics;
    $('#feedback-diagnostics').hidden = !diagnostics;
    $('#feedback-no-diagnostics').hidden = Boolean(diagnostics);
    clearError('feedback-error');
    $('#feedback-dialog').showModal();
  } catch (err) {
    toast(err.message);
  }
}

$('#feedback-delete').addEventListener('click', async () => {
  if (!feedbackDetail) return;
  const ok = await askConfirm({
    title: '删除这条反馈？',
    message: '正文与诊断摘要将一起删除，无法恢复。保留期到期的反馈本来会由每日清理删除。',
    ok: '删除',
    danger: true,
  });
  if (!ok) return;
  try {
    await api('DELETE', '/feedback/' + encodeURIComponent(feedbackDetail.id));
    $('#feedback-dialog').close();
    toast('反馈已删除。');
    if (state.feedback.length === 1 && state.feedbackOffset > 0) {
      state.feedbackOffset = Math.max(0, state.feedbackOffset - state.feedbackLimit);
    }
    await loadFeedback();
  } catch (err) {
    showError('feedback-error', err.message);
  }
});

// ---- 启动 ----
if (state.token) signIn(state.token);
