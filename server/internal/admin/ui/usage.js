import { $, state, api, el, number, percent, kindList, kindName, routeShare, openTab } from './shared.js';

// ---- 路由统计 ----
let usageRequest;
let usageFilters = {};
let usageDay = null;
let report = null;
const axisNumber = new Intl.NumberFormat('zh-CN', { notation: 'compact', maximumFractionDigits: 1 });
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

// 已有日汇总的输入量含缺报记录，只有上报完整时才有可用的命中率分母。
function cacheRatio(input, cached, inputReports, cachedReports) {
  return input > 0 && inputReports > 0 && inputReports === cachedReports
    ? routeShare(cached / input) : '';
}

function cacheHitRate(u) {
  if (u.input_tokens !== u.first_input_tokens + u.failover_input_tokens) return '';
  return cacheRatio(u.input_tokens, u.cached_tokens,
    u.first_input_reports + u.failover_input_reports, u.first_cached_reports + u.failover_cached_reports);
}

function cacheNotes(u) {
  const reports = u.first_input_reports + u.failover_input_reports;
  const reported = u.first_cached_reports + u.failover_cached_reports;
  const parts = [];
  const hit = cacheHitRate(u);
  if (hit) parts.push(`输入缓存命中 ${hit}`);
  const first = cacheRatio(u.first_input_tokens, u.first_cached_tokens, u.first_input_reports, u.first_cached_reports);
  const failover = cacheRatio(u.failover_input_tokens, u.failover_cached_tokens, u.failover_input_reports, u.failover_cached_reports);
  if (!hit && first) parts.push(`首次命中 ${first}`);
  if (!hit && failover) parts.push(`换路命中 ${failover}`);
  if (hit && first && failover) parts.push(`首次 ${first} · 换路 ${failover}`);
  if (reports > reported) parts.push(`缓存字段缺报 ${number.format(reports - reported)}/${number.format(reports)} 条`);
  if (u.input_tokens !== u.first_input_tokens + u.failover_input_tokens) parts.push('部分输入缺少缓存字段覆盖记录');
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
  openTab('usage');
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
  report = null;
  const status = $('#usage-status');
  status.textContent = '正在读取用量…';
  status.hidden = false;
  $('#usage-period').textContent = '';
  $('#usage-report').hidden = true;
  try {
    const result = await api('GET', '/usage?days=' + $('#usage-days').value, null, current.signal);
    if (current.signal.aborted) return;
    report = result;
    renderUsage();
    status.hidden = true;
    $('#usage-report').hidden = false;
  } catch (err) {
    if (!current.signal.aborted) {
      status.textContent = '读取用量失败。' + err.message;
    }
  }
}

function resetUsage() {
  usageRequest?.abort();
  report = null;
  usageFilters = {};
  usageDay = null;
}

function renderUsage() {
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
    ? `${date} · ${number.format(total.tokens)} Token（含估算 ${number.format(total.estimated_tokens)}） · ${number.format(total.attempts)} 次尝试（${number.format(total.first_attempts)} 首次，${number.format(total.failover_attempts)} 故障切换） · ${number.format(total.attempts - total.successes)} 次未成功${cacheHitRate(day.chat) ? ` · 输入缓存命中 ${cacheHitRate(day.chat)}` : ''}`
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
    target.append(el('tr', {}, el('td', { colspan: 9, class: 'empty' }, '没有符合条件的用量记录。')));
    return;
  }
  const sorted = [...rows.values()].sort((a, b) => b.usage.tokens - a.usage.tokens || b.usage.attempts - a.usage.attempts || a.label.localeCompare(b.label));
  for (const { label, sub, kind, usage: u } of sorted) {
    const incomplete = [
      u.truncated_attempts ? `截断 ${number.format(u.truncated_attempts)}` : '',
      u.canceled_attempts ? `取消 ${number.format(u.canceled_attempts)}` : '',
    ].filter(Boolean).join(' · ');
    const cache = kind === 'chat' ? cacheNotes(u) : '';
    target.append(el('tr', {}, el('td', {}, el('span', { class: 'mono' }, label), sub ? el('div', { class: 'sub mono' }, sub) : null),
      el('td', { class: 'nowrap' }, kindName[kind]),
      el('td', { class: 'numeric' }, number.format(u.tokens),
        cache ? el('div', { class: 'sub' }, cache) : null),
      [u.estimated_tokens, u.attempts, u.first_attempts, u.failover_attempts]
        .map((n) => el('td', { class: 'numeric' }, number.format(n))),
      el('td', { class: 'numeric' }, number.format(u.attempts - u.successes), incomplete ? el('div', { class: 'sub' }, incomplete) : null),
      el('td', { class: 'numeric' }, successRate(u))));
  }
}


export { loadUsage, resetUsage, openRouteUsage };
