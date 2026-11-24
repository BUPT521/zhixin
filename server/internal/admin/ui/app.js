// 知新模型后台。只调用 /admin/v1/ 接口，令牌放在 sessionStorage，关闭标签页即失效。
// 所有来自接口的文字一律用 textContent 写入，不拼 HTML。
'use strict';

const $ = (sel) => document.querySelector(sel);
const state = {
  token: sessionStorage.getItem('zhixin-admin-token') || '',
  providers: [], models: [], upstreamNames: new Map(), usage: null,
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
  state.usage = null;
  usageFilters = {};
  usageDay = null;
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
    } else if (health.state === 'cooling') {
      badge = '冷却中';
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
  ready: '可用', cooling: '冷却中', disabled: '路由停用',
  provider_disabled: '来源停用', key_error: '密钥异常', provider_missing: '来源缺失',
};
const routeBadge = {
  ready: 'ok', cooling: 'cooling', disabled: 'off',
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
  const health = providerHealth(route.provider_id);
  const parts = [];
  if (route.state === 'cooling' && health.cooling_until) parts.push('冷却到 ' + clock(health.cooling_until));
  if (health.consecutive_failures) parts.push(`连续失败 ${health.consecutive_failures} 次`);
  if (!parts.length && health.last_error && route.state !== 'ready' && route.state !== 'disabled') {
    parts.push('最近错误：' + health.last_error);
  }
  return parts.join(' · ');
}

function modelNeedsAttention(m) {
  return !m.enabled || !m.available ||
    m.routes.some((r) => ['cooling', 'key_error', 'provider_disabled', 'provider_missing'].includes(r.state)) ||
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
    const usable = m.routes.filter((r) => r.state === 'ready' || r.state === 'cooling').length;
    const tone = !m.enabled ? 'off' : m.available ? 'ok' : 'warn';
    const label = !m.enabled ? '已停用' : m.available ? '可调用' : '无可用路由';
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

// 与 Router.candidates 一致，先按组尝试未冷却的路由，再按同样的组顺序尝试冷却路由。
function candidateGroups(groups) {
  return ['ready', 'cooling'].flatMap((state) => groups.map(({ name, routes }) => ({
    name, state, routes: routes.filter((route) => route.state === state),
  }))).filter((group) => group.routes.length);
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
    const ordered = [...routes].sort((a, b) =>
      a.provider_id.localeCompare(b.provider_id) || a.upstream_model.localeCompare(b.upstream_model));
    out.push(el('div', { class: 'route-group' }, name));
    for (const route of ordered) {
      const share = first.includes(route) ? route.weight / total : null;
      out.push(routeRow(m, route, share));
    }
  }
  return out;
}

function routeRow(m, r, firstShare) {
  const meta = [];
  if (firstShare !== null) meta.push(`首选 ${routeShare(firstShare)}`);
  if (m.kind === 'embedding' && r.max_batch) meta.push(`每批 ${r.max_batch} 条`);
  const health = routeHealthText(r);
  return el('div', { class: 'route' + (r.state === 'ready' || r.state === 'cooling' ? '' : ' is-off') },
    el('div', { class: 'route-main' },
      el('span', { class: 'mono route-name', title: r.provider_id }, providerLabel(r.provider_id) + ' → ' + r.upstream_model),
      el('span', { class: 'badge ' + (routeBadge[r.state] || 'off') }, routeState[r.state] || r.state),
      meta.length ? el('span', { class: 'route-meta' }, meta.join(' · ')) : null,
      health ? el('span', { class: 'route-health', title: providerHealth(r.provider_id).last_error || '' }, health) : null,
    ),
    el('span', { class: 'route-ops' },
      el('button', { type: 'button', class: 'link', disabled: !(r.state === 'ready' || r.state === 'cooling'),
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
$('#model-form').elements.kind.addEventListener('change', syncKind);
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
  const weight = el('input', { name: 'weight', type: 'number', min: 1, max: 1000, step: 1, inputmode: 'numeric', value: route.weight ?? 1 });
  const batch = el('input', { name: 'max_batch', type: 'number', min: 0, max: 2048, step: 1, inputmode: 'numeric', value: route.max_batch ?? 0, title: '0 表示不拆分' });
  const enabled = el('input', { name: 'route_enabled', type: 'checkbox', checked: route.enabled ?? true });
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
      el('span', { class: 'field-label' }, '权重'),
      el('span', { class: 'weight-input' }, weight, el('span', { class: 'field-hint route-config-share', 'aria-hidden': 'true' })),
    ),
    el('label', { class: 'route-field field-num emb-only' },
      el('span', { class: 'field-label' }, '每批条数'),
      batch,
    ),
    el('label', { class: 'check route-enabled' }, enabled, '启用'),
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
  };
}

function renderRoutePreview() {
  const modelEnabled = $('#model-form').elements.enabled.checked;
  const providers = new Map(state.providers.map((provider) => [provider.id, provider]));
  const groups = [...$('#route-rows').children].map((group, index) => {
    const rows = [...group.querySelectorAll('.route-edit')];
    const routes = rows.map(readRouteRow);
    const total = routeWeight(routes.filter((route) => route.enabled));
    for (const [i, route] of routes.entries()) {
      rows[i].querySelector('.route-config-share').textContent = route.enabled && total > 0
        ? `组内 ${routeShare(route.weight / total)}` : '';
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
      const cooling = provider?.health.state === 'cooling' || scenario === 'all' || scenario === `source:${route.provider_id}` ||
        (scenario === 'primary' && primarySources.has(route.provider_id));
      route.state = modelEnabled && route.enabled && provider?.enabled && provider.health.state !== 'key_error'
        ? (cooling ? 'cooling' : 'ready') : 'disabled';
    }
  }
  const result = $('#route-preview-result');
  const candidates = candidateGroups(groups);
  if (candidates.length === 0) {
    result.replaceChildren(el('p', { class: 'field-hint' }, modelEnabled ? '当前没有可尝试的路由。' : '模型停用后暂停路由。'));
    return;
  }
  if (groups.some(({ routes }) => routes.some((route) => route.enabled && !route.upstream_model))) {
    result.replaceChildren(el('p', { class: 'field-hint' }, '填写启用路由的来源侧模型名后即可预览。'));
    return;
  }
  const first = candidates[0];
  const total = routeWeight(first.routes);
  if (!Number.isFinite(total)) {
    result.replaceChildren(el('p', { class: 'field-hint warn' }, '请使用 1 到 1000 的整数作为权重。'));
    return;
  }
  const order = candidates.map((group) => group.name + (group.state === 'cooling' ? '（冷却中）' : '')).join(' → ');
  result.replaceChildren(
    el('p', { class: 'field-hint' }, `候选组顺序 ${order}`),
    el('ul', { class: 'route-preview-list' }, first.routes.map((route) => {
      const name = `${providerLabel(route.provider_id)} → ${route.upstream_model}`;
      const share = route.weight / total;
      return el('li', {},
        el('span', { class: 'route-preview-name' }, name),
        el('progress', { max: 1, value: share, 'aria-hidden': 'true' }),
        el('span', { class: 'route-preview-share' }, routeShare(share)),
      );
    })),
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
    showProbe(title,
      el('p', {}, el('span', { class: r.ok ? 'ok' : 'bad' }, r.ok ? '可用' : '不可用'),
        `　耗时 ${r.latency_ms} ms`, r.status ? `　HTTP ${r.status}` : ''),
      r.provider_id ? el('p', { class: 'mono' }, `实际走的路由：${r.provider_id} → ${r.upstream_model}`) : null,
      r.dimensions ? el('p', {}, `返回向量 ${r.dimensions} 维` + (m.dimensions && m.dimensions !== r.dimensions ? `，与配置的 ${m.dimensions} 维不一致` : '')) : null,
      r.error ? el('p', {}, r.error) : null,
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
const usagePart = () => ({ attempts: 0, successes: 0, tokens: 0, estimated_tokens: 0 });
function addUsage(total, part) {
  for (const field of Object.keys(total)) total[field] += part[field];
  return total;
}
function successRate(u) {
  return u.attempts ? percent.format(u.successes / u.attempts) : '—';
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
  } catch (err) {
    if (!current.signal.aborted) status.textContent = '读取用量失败。' + err.message;
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
  $('#usage-period').textContent = `${days[0].day} 至 ${days.at(-1).day} · ${report.timezone}`;
  $('#usage-tokens').textContent = number.format(totals.tokens);
  $('#usage-estimate').textContent = `含估算 ${number.format(totals.estimated_tokens)}`;
  $('#usage-attempts').textContent = number.format(totals.attempts);
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
    ? `${date} · ${number.format(total.tokens)} Token（含估算 ${number.format(total.estimated_tokens)}） · ${number.format(total.attempts)} 次尝试 · ${number.format(total.attempts - total.successes)} 次未成功`
    : ($('#usage-chart-wrap').hidden ? '' : '选择日期查看当天明细。');
  renderUsageTable(routes, date);
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
    target.append(el('tr', {}, el('td', { colspan: 7, class: 'empty' }, '没有符合条件的用量记录。')));
    return;
  }
  const sorted = [...rows.values()].sort((a, b) => b.usage.tokens - a.usage.tokens || b.usage.attempts - a.usage.attempts || a.label.localeCompare(b.label));
  for (const { label, sub, kind, usage: u } of sorted) {
    target.append(el('tr', {}, el('td', {}, el('span', { class: 'mono' }, label), sub ? el('div', { class: 'sub mono' }, sub) : null),
      el('td', { class: 'nowrap' }, kindName[kind]),
      [u.tokens, u.estimated_tokens, u.attempts, u.attempts - u.successes].map((n) => el('td', { class: 'numeric' }, number.format(n))),
      el('td', { class: 'numeric' }, successRate(u))));
  }
}

// ---- 启动 ----
if (state.token) signIn(state.token);
