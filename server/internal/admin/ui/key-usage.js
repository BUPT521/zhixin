import { $, api, el, number, moment, openTab } from './shared.js';

let request;
let userID = '';
let selectedDay = '';
let report;

function openKeyUsage(id) {
  userID = id;
  $('#key-usage-user').value = id;
  selectedDay = '';
  loadKeyUsage();
}

function resetKeyUsage() {
  request?.abort();
  report = null;
  userID = '';
  selectedDay = '';
  $('#key-usage-user').value = '';
}

async function loadKeyUsage() {
  request?.abort();
  const current = new AbortController();
  request = current;
  report = null;
  const status = $('#key-usage-status');
  status.textContent = '正在读取密钥用量…';
  status.hidden = false;
  $('#key-usage-period').textContent = '';
  $('#key-usage-report').hidden = true;
  $('#clear-key-usage-user').hidden = !userID;

  const params = new URLSearchParams({ days: $('#key-usage-days').value });
  if (userID) params.set('user_id', userID);
  try {
    const result = await api('GET', '/key-usage?' + params, null, current.signal);
    if (current.signal.aborted) return;
    report = result;
    $('#key-usage-period').textContent = `${report.from_day} 至 ${report.to_day} · ${report.timezone}`;
    populateDates();
    renderKeyUsage();
    $('#key-usage-report').hidden = false;
    status.hidden = true;
  } catch (err) {
    if (!current.signal.aborted) status.textContent = '读取密钥用量失败。' + err.message;
  }
}

function reportDates() {
  const dates = [];
  const date = new Date(report.from_day);
  const last = new Date(report.to_day);
  for (; date <= last; date.setUTCDate(date.getUTCDate() + 1)) {
    dates.push(date.toISOString().slice(0, 10));
  }
  return dates;
}

function populateDates() {
  const dates = reportDates();
  if (!dates.includes(selectedDay)) selectedDay = '';
  const field = $('#key-usage-day');
  field.replaceChildren(el('option', { value: '' }, '整个区间'),
    ...dates.map((day) => el('option', { value: day }, day)));
  field.value = selectedDay;
}

function keyUsageRow(key, usage, dates, peak, perPoint) {
  const tokenRow = !key.key_id;
  const name = tokenRow ? '访问令牌' : key.key_present ? key.name || '未命名密钥' : '已清理的密钥';
  const status = tokenRow ? '—' : !key.key_present ? '已清理' : key.revoked ? '已撤销' : '在用';
  const sub = tokenRow ? '客户端调用' : key.prefix || key.key_id;
  const points = perPoint > 0 ? '≈' + number.format(Math.ceil((usage.chat.tokens + usage.embedding.tokens) / perPoint)) : '—';
  const shortID = key.user_id.length <= 12 ? key.user_id : key.user_id.slice(0, 8) + '…';
  const spark = el('span', { class: 'key-spark' });
  for (const day of dates) {
    const observation = key.daily[day];
    const tokens = observation ? observation.chat.tokens + observation.embedding.tokens : 0;
    const bar = el('span', {
      class: tokens ? 'key-spark-bar' : 'key-spark-bar key-spark-empty',
      title: `${day}：${number.format(tokens)} Token`,
    });
    bar.style.height = tokens ? `${Math.max(6, tokens / peak * 100)}%` : '2px';
    spark.append(bar);
  }
  return el('tr', {},
    el('td', {}, el('span', { class: 'mono' }, name), el('div', { class: 'sub mono' }, sub)),
    el('td', {}, el('button', { type: 'button', class: 'link mono', title: key.user_id,
      'aria-label': `在账号管理中查找 ${key.user_id}`, onclick: () => openTab('accounts', key.user_id) }, shortID)),
    el('td', { class: 'numeric' }, number.format(usage.chat.tokens)),
    el('td', { class: 'numeric' }, points),
    el('td', { class: 'numeric' }, number.format(usage.embedding.tokens)),
    el('td', { class: 'numeric' }, number.format(usage.chat.attempts + usage.embedding.attempts)),
    el('td', { class: 'numeric' }, number.format(usage.chat.failures + usage.embedding.failures)),
    el('td', { class: 'numeric' }, number.format(usage.chat.reserved_tokens + usage.embedding.reserved_tokens)),
    el('td', { class: 'numeric' }, spark),
    el('td', { class: 'nowrap' }, key.last_used_at ? moment(key.last_used_at) : '—'),
    el('td', {}, status));
}

function renderKeyUsage() {
  if (!report) return;
  const perPoint = report.tokens_per_point;
  const dates = reportDates();
  const peak = report.keys.reduce((max, key) => Object.values(key.daily)
    .reduce((value, day) => Math.max(value, day.chat.tokens + day.embedding.tokens), max), 1);

  const rows = [];
  let chat = 0, embedding = 0, reserved = 0, attempts = 0, failures = 0;
  for (const key of report.keys) {
    const usage = selectedDay ? key.daily[selectedDay] : key;
    if (!usage) continue;
    chat += usage.chat.tokens;
    embedding += usage.embedding.tokens;
    reserved += usage.chat.reserved_tokens + usage.embedding.reserved_tokens;
    attempts += usage.chat.attempts + usage.embedding.attempts;
    failures += usage.chat.failures + usage.embedding.failures;
    rows.push({ key, usage });
  }
  rows.sort((a, b) => b.usage.chat.tokens - a.usage.chat.tokens ||
    b.usage.embedding.tokens - a.usage.embedding.tokens || a.key.user_id.localeCompare(b.key.user_id) ||
    a.key.key_id.localeCompare(b.key.key_id));
  const body = $('#key-usage-rows');
  body.replaceChildren();
  if (rows.length) {
    const fragment = document.createDocumentFragment();
    for (const { key, usage } of rows) fragment.append(keyUsageRow(key, usage, dates, peak, perPoint));
    body.append(fragment);
  } else {
    body.append(el('tr', {}, el('td', { class: 'empty', colspan: 11 }, '所选范围内没有调用记录。')));
  }
  $('#key-usage-chat').textContent = number.format(chat);
  $('#key-usage-embedding').textContent = number.format(embedding);
  $('#key-usage-attempts').textContent = number.format(attempts);
  $('#key-usage-ratio').textContent = perPoint > 0 ? `每积分 ${number.format(perPoint)} 计费 Token` : '未配置积分比例';
  $('#key-usage-reserved').textContent = `聊天与嵌入共 ${number.format(reserved)} Token 在途`;
  $('#key-usage-failures').textContent = `${number.format(failures)} 次未成功`;
}

$('#key-usage-filter').addEventListener('submit', (event) => {
  event.preventDefault();
  userID = $('#key-usage-user').value.trim();
  loadKeyUsage();
});
$('#clear-key-usage-user').addEventListener('click', () => {
  userID = '';
  $('#key-usage-user').value = '';
  $('#key-usage-user').focus();
  loadKeyUsage();
});
$('#refresh-key-usage').addEventListener('click', loadKeyUsage);
$('#key-usage-days').addEventListener('change', loadKeyUsage);
$('#key-usage-day').addEventListener('change', (event) => {
  selectedDay = event.target.value;
  renderKeyUsage();
});

export { loadKeyUsage, resetKeyUsage, openKeyUsage };
