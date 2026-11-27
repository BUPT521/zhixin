import { $, api, el, number, percent } from './shared.js';

const state = { retention: null };
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


function resetRetention() {
  retentionRequest?.abort();
  state.retention = null;
}

export { loadRetention, resetRetention };
