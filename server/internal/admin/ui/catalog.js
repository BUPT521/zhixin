import {
  $, state, api, el, toast, kindName, moment, routeShare,
  markClean, askConfirm, showError, clearError, runSave,
} from './shared.js';
import { openRouteUsage } from './usage.js';

async function loadCatalog() {
  const token = state.token;
  const [p, m] = await Promise.all([api('GET', '/providers'), api('GET', '/models')]);
  if (token !== state.token) return;
  state.providers = p.data;
  state.models = m.data;
  renderProviders();
  renderModels();
  if ($('#model-dialog').open) renderRoutePreview();
}

function refresh() {
  return loadCatalog().catch((err) => toast(err.message));
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
  if (firstShare !== null) meta.push(`健康权重占比 ${routeShare(firstShare)}`);
  else if (routeEligible(r)) meta.push('前组不可用或失败后尝试');
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
        : routeEligible(route) ? '前组不可用或失败后尝试' : routeState[route.state];
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


export { loadCatalog, closeProbe };
