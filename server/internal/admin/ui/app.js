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
  const res = await fetch('/admin/v1' + path, {
    method,
    headers: { Authorization: 'Bearer ' + state.token, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
    signal,
  });
  if (res.status === 204) return null;
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    if (res.status === 401) logout('令牌不对或已失效');
    const err = new Error(problemText(data, res.status));
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
  state.token = $('#token').value.trim();
  try {
    await loadAll();
    sessionStorage.setItem('zhixin-admin-token', state.token);
    $('#token').value = '';
    showApp(true);
  } catch (err) {
    toast(err.message);
  }
});
$('#logout').addEventListener('click', () => logout());

function logout(msg) {
  state.token = '';
  sessionStorage.removeItem('zhixin-admin-token');
  usageRequest?.abort();
  state.usage = null;
  usageFilters = {};
  usageDay = null;
  state.upstreamNames.clear();
  selectTab(tabs[0]);
  showApp(false);
  if (msg) toast(msg);
}

function showApp(on) {
  $('#app').hidden = !on;
  $('#session').hidden = !on;
  $('#login').hidden = on;
}

// ---- 标签页 ----
const tabs = [...document.querySelectorAll('[role=tab]')];
function selectTab(tab) {
  closeProbe();
  for (const item of tabs) {
    const selected = item === tab;
    item.setAttribute('aria-selected', String(selected));
    item.tabIndex = selected ? 0 : -1;
    document.getElementById(item.getAttribute('aria-controls')).hidden = !selected;
  }
  if (tab.dataset.tab === 'usage') loadUsage();
}
tabs.forEach((tab, index) => {
  tab.addEventListener('click', () => selectTab(tab));
  tab.addEventListener('keydown', (e) => {
    const next = { ArrowLeft: (index + tabs.length - 1) % tabs.length, ArrowRight: (index + 1) % tabs.length, Home: 0, End: tabs.length - 1 }[e.key];
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
  renderEnvNote();
}

// ---- 来源 ----
const stateText = { ok: '正常', cooling: '冷却中', key_error: 'key 无法解密' };

function renderProviders() {
  const body = $('#providers');
  body.replaceChildren();
  if (!state.providers.length) {
    body.append(el('tr', {}, el('td', { colspan: 6, class: 'empty' }, '还没有来源。点右上角“新增来源”。')));
    return;
  }
  for (const p of state.providers) {
    const h = p.health;
    const status = el('td', {},
      p.enabled ? el('span', { class: 'badge ' + h.state }, stateText[h.state] || h.state) : el('span', { class: 'badge off' }, '已停用'),
      h.consecutive_failures ? el('div', { class: 'sub' }, `连续失败 ${h.consecutive_failures} 次`) : null,
      h.last_error ? el('div', { class: 'sub', title: h.last_error_at || '' }, '最近错误：' + h.last_error) : null,
      h.cooling_until ? el('div', { class: 'sub' }, '冷却到 ' + new Date(h.cooling_until).toLocaleTimeString()) : null,
    );
    const env = p.source === 'env';
    body.append(el('tr', {},
      el('td', {}, el('span', { class: 'mono' }, p.id), env ? el('div', { class: 'sub' }, el('span', { class: 'badge env' }, '只读'), ' 不能作为后台模型的路由') : null),
      el('td', { class: 'name' }, p.name, p.note ? el('div', { class: 'sub' }, p.note) : null),
      el('td', { class: 'mono url' }, p.base_url),
      el('td', { class: 'mono' }, p.has_key ? '••••' + (p.key_hint || '') : '未设置'),
      status,
      el('td', { class: 'ops' },
        el('button', { class: 'link', onclick: () => testProvider(p) }, '测试'),
        env ? null : el('button', { class: 'link', onclick: () => editProvider(p) }, '编辑'),
        env ? null : el('button', { class: 'danger', onclick: () => deleteProvider(p) }, '删除'),
      ),
    ));
  }
}

$('#add-provider').addEventListener('click', () => editProvider(null));

function editProvider(p) {
  const f = $('#provider-form');
  f.reset();
  $('#provider-title').textContent = p ? '编辑来源 ' + p.id : '新增来源';
  f.id.value = p ? p.id : '';
  f.id.readOnly = !!p;
  f.name.value = p ? p.name : '';
  f.base_url.value = p ? p.base_url : '';
  f.api_key.placeholder = p && p.has_key ? '留空表示不修改（当前末四位 ' + (p.key_hint || '') + '）' : '没有 key 时留空';
  f.clear_key.parentElement.hidden = !(p && p.has_key);
  f.enabled.checked = p ? p.enabled : true;
  f.note.value = p ? p.note : '';
  $('#provider-error').hidden = true;
  $('#provider-dialog').showModal();
}

$('#provider-form').addEventListener('submit', async (e) => {
  if (e.submitter && e.submitter.value === 'cancel') return;
  e.preventDefault();
  const f = e.target;
  const body = { base_url: f.base_url.value.trim(), name: f.name.value.trim(), enabled: f.enabled.checked, note: f.note.value.trim() };
  if (f.api_key.value.trim()) body.api_key = f.api_key.value.trim();
  else if (f.clear_key.checked) body.api_key = '';
  try {
    await api('PUT', '/providers/' + encodeURIComponent(f.id.value.trim()), body);
    state.upstreamNames.delete(f.id.value.trim());
    $('#provider-dialog').close();
    toast('已保存，路由立即生效');
    await loadAll();
  } catch (err) {
    const box = $('#provider-error');
    box.textContent = err.message;
    box.hidden = false;
  }
});

async function deleteProvider(p) {
  if (!confirm(`删除来源 ${p.id}？有模型路由指向它时会被拒绝。`)) return;
  try {
    await api('DELETE', '/providers/' + encodeURIComponent(p.id));
    state.upstreamNames.delete(p.id);
    toast('已删除');
    await loadAll();
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
  ready: '可用', cooling: '冷却中', disabled: '已停用',
  provider_disabled: '来源已停用', key_error: 'key 无法解密', provider_missing: '来源缺失',
};
const routeRank = { ready: 0, cooling: 1 };
const kindName = { chat: '聊天', embedding: '嵌入' };
const kindList = ['chat', 'embedding'];

function renderModels() {
  const body = $('#models');
  body.replaceChildren();
  if (!state.models.length) {
    body.append(el('tr', {}, el('td', { colspan: 5, class: 'empty' }, '还没有对外模型。先新增来源，再新增模型并配置路由。')));
    return;
  }
  for (const m of state.models) {
    const env = m.source === 'env';
    body.append(el('tr', {},
      el('td', {}, el('span', { class: 'mono' }, m.name), m.note ? el('div', { class: 'sub' }, m.note) : null,
        env ? el('div', { class: 'sub' }, el('span', { class: 'badge env' }, '环境变量 · 只读')) : null),
      el('td', { class: 'nowrap' }, kindName[m.kind], m.dimensions ? el('div', { class: 'sub' }, m.dimensions + ' 维') : null),
      el('td', {}, [...m.routes].sort((a, b) => (routeRank[a.state] ?? 2) - (routeRank[b.state] ?? 2) || a.priority - b.priority).map((r) =>
        el('div', { class: 'route' },
          el('span', { class: 'mono' }, `${r.provider_id} → ${r.upstream_model}`),
          el('span', { class: 'sub' }, `优先级 ${r.priority} · 权重 ${r.weight}` + (m.kind === 'embedding' && r.max_batch ? ` · 每批 ${r.max_batch}` : '')),
          el('span', { class: 'badge ' + ({ ready: 'ok', cooling: 'cooling' }[r.state] || 'off') }, routeState[r.state]),
          el('span', { class: 'route-actions' },
            el('button', { type: 'button', class: 'link', disabled: !(r.state in routeRank),
              'aria-label': `探测 ${m.name} 的 ${r.provider_id} / ${r.upstream_model} 路由`,
              onclick: () => testModel(m, r) }, '探测'),
            el('button', { type: 'button', class: 'link', 'aria-label': `查看 ${m.name} 的 ${r.provider_id} / ${r.upstream_model} 路由用量`,
              onclick: () => openRouteUsage(m, r) }, '用量')),
        ))),
      el('td', {}, el('span', { class: 'badge ' + (m.available ? 'ok' : 'off') }, m.available ? '可调用' : (m.enabled ? '无可用路由' : '已停用'))),
      el('td', { class: 'ops' },
        el('button', { class: 'link', disabled: !m.available, onclick: () => testModel(m) }, '测试模型'),
        env ? null : el('button', { class: 'link', onclick: () => editModel(m) }, '编辑'),
        env ? null : el('button', { class: 'danger', onclick: () => deleteModel(m) }, '删除'),
      ),
    ));
  }
}

$('#add-model').addEventListener('click', () => editModel(null));
$('#refresh-models').addEventListener('click', () => loadAll().catch((err) => toast(err.message)));
$('#add-route').addEventListener('click', () => addRouteRow({}));
$('#model-form').kind.addEventListener('change', syncKind);

function syncKind() {
  const emb = $('#model-form').kind.value === 'embedding';
  document.querySelectorAll('#model-dialog .emb-only').forEach((n) => { n.hidden = !emb; });
}

function adminProviders() { return state.providers.filter((p) => p.source === 'admin'); }

// 环境变量来源不能作为路由，只有它的时候后台建不了模型；在模型页直接说明，
// 免得“新增模型”的提示和来源列表里那个来源看起来矛盾。
function renderEnvNote() {
  $('#models-env-note').hidden = !(adminProviders().length === 0 && state.providers.some((p) => p.source === 'env'));
}

let routeRowID = 0;
function addRouteRow(r) {
  const select = el('select', { name: 'provider_id', required: true },
    adminProviders().map((p) => el('option', { value: p.id, selected: p.id === r.provider_id }, p.id + (p.enabled ? '' : '（已停用）'))));
  const suggestions = el('datalist', { id: 'upstream-names-' + ++routeRowID });
  const updateSuggestions = () => {
    suggestions.replaceChildren(...(state.upstreamNames.get(select.value) || []).map((name) => el('option', { value: name })));
  };
  select.addEventListener('change', updateSuggestions);
  updateSuggestions();
  const discover = el('button', { type: 'button', class: 'link' }, '获取模型列表');
  discover.addEventListener('click', async () => {
    const provider = select.value;
    const token = state.token;
    discover.disabled = true;
    try {
      const result = await api('POST', '/providers/' + encodeURIComponent(provider) + '/test');
      if (state.token !== token) return;
      if (!result.ok) throw new Error(result.error || '无法获取模型列表');
      const names = result.models || [];
      state.upstreamNames.set(provider, names);
      updateSuggestions();
      toast(names.length ? `已读取 ${names.length} 个模型，可在模型名输入框中选择` : '来源未列出模型，可以手工填写');
    } catch (err) {
      toast(err.message);
    } finally {
      discover.disabled = false;
    }
  });
  const row = el('tr', {},
    el('td', {}, select),
    el('td', {}, el('input', { name: 'upstream_model', required: true, list: suggestions.id, value: r.upstream_model || '', placeholder: '例如 deepseek-chat、BAAI/bge-m3' }), suggestions, discover),
    el('td', {}, el('input', { name: 'priority', type: 'number', min: 0, max: 100, value: r.priority ?? 0 })),
    el('td', {}, el('input', { name: 'weight', type: 'number', min: 1, max: 1000, value: r.weight ?? 1 })),
    el('td', { class: 'emb-only' }, el('input', { name: 'max_batch', type: 'number', min: 0, max: 2048, value: r.max_batch ?? 0, title: '0 表示不拆分' })),
    el('td', { class: 'tick' }, el('input', { name: 'route_enabled', type: 'checkbox', checked: r.enabled ?? true })),
    el('td', {}, el('button', { type: 'button', class: 'danger', onclick: () => row.remove() }, '移除')),
  );
  $('#route-rows').append(row);
  syncKind();
}

function editModel(m) {
  if (!adminProviders().length) {
    // 环境变量来源只读，后台的模型路由引用不了它，所以有这个来源也新建不了模型。
    toast(state.providers.some((p) => p.source === 'env')
      ? '环境变量来源只读，不能作为路由；先在“模型来源”新增一个来源'
      : '先新增至少一个来源');
    return;
  }
  const f = $('#model-form');
  f.reset();
  $('#model-title').textContent = m ? '编辑模型 ' + m.name : '新增模型';
  f.name.value = m ? m.name : '';
  f.name.readOnly = !!m;
  f.kind.value = m ? m.kind : 'chat';
  f.dimensions.value = m && m.dimensions ? m.dimensions : '';
  f.enabled.checked = m ? m.enabled : true;
  f.note.value = m ? m.note : '';
  $('#route-rows').replaceChildren();
  (m ? m.routes : [{}]).forEach(addRouteRow);
  $('#model-error').hidden = true;
  syncKind();
  $('#model-dialog').showModal();
}

$('#model-form').addEventListener('submit', async (e) => {
  if (e.submitter && e.submitter.value === 'cancel') return;
  e.preventDefault();
  const f = e.target;
  const kind = f.kind.value;
  const routes = [...document.querySelectorAll('#route-rows tr')].map((tr) => {
    const v = (n) => tr.querySelector(`[name=${n}]`);
    const route = {
      provider_id: v('provider_id').value,
      upstream_model: v('upstream_model').value.trim(),
      priority: Number(v('priority').value || 0),
      weight: Number(v('weight').value || 1),
      enabled: v('route_enabled').checked,
    };
    if (kind === 'embedding') route.max_batch = Number(v('max_batch').value || 0);
    return route;
  });
  const body = { kind, enabled: f.enabled.checked, note: f.note.value.trim(), routes };
  if (kind === 'embedding' && f.dimensions.value) body.dimensions = Number(f.dimensions.value);
  try {
    await api('PUT', '/models/' + encodeURIComponent(f.name.value.trim()), body);
    $('#model-dialog').close();
    toast('已保存，路由立即生效');
    await loadAll();
  } catch (err) {
    const box = $('#model-error');
    box.textContent = err.message;
    box.hidden = false;
  }
});

async function deleteModel(m) {
  if (!confirm(`删除模型 ${m.name}？客户端再请求这个名字会得到 model_not_allowed。`)) return;
  try {
    await api('DELETE', '/models/' + encodeURIComponent(m.name));
    toast('已删除');
    await loadAll();
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
    loadAll().catch((err) => {
      if (!signal.aborted) toast(err.message);
    });
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
if (state.token) {
  loadAll().then(() => showApp(true)).catch(() => logout());
}
