import { $, el, api, toast, number, moment, openTab, askConfirm, markClean, requestClose, showError, clearError, runSave } from './shared.js';

// ---- 账号管理 ----
// 账号页只调用 /admin/v1/accounts 下的接口。列表带额度覆盖值与生效值，单独读取
// 一个账号时再取今日已结算用量；注销与恢复默认都要求二次确认，删除请求体里
// 再提交一次账号编号，编号看错时不会误删另一个账号。
const state = { accounts: [], accountTotal: 0, accountLimit: 20, accountOffset: 0, accountQuery: '' };
let detailRequest;
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
      quotaText('共享', quota.daily_tokens, quota.daily_tokens_override),
      quota.note ? el('div', { class: 'sub' }, quota.note) : null),
    el('td', { class: 'ops', 'data-label': '操作' }, el('div', { class: 'row-actions' },
      el('button', { type: 'button', class: 'link', 'aria-label': `查看 ${account.id} 的账号详情`,
        onclick: () => openQuota(account) }, '详情'),
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
  $('#accounts').replaceChildren();
  $('#account-summary').textContent = '';
  $('#account-filter-count').textContent = '';
  $('#account-page').textContent = '';
  $('#account-prev').disabled = true;
  $('#account-next').disabled = true;
  status.textContent = '正在读取账号…';
  status.hidden = false;
  const params = new URLSearchParams({
    limit: String(state.accountLimit), offset: String(state.accountOffset),
  });
  if (state.accountQuery) params.set('query', state.accountQuery);
  try {
    const data = await api('GET', '/accounts?' + params, null, controller.signal);
    if (controller.signal.aborted) return;
    state.accounts = data.data || [];
    state.accountTotal = data.total || 0;
    renderAccounts();
    status.hidden = true;
  } catch (err) {
    if (controller.signal.aborted) return;
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

// 积分一节只读：余额在支付宝一侧，服务端保存的是一份副本，后台可以刷新但不能
// 补分、扣分或退款。没有开通收款、还没有副本与确实为零是三种不同的状态，文案分开。
const pointChargeStatus = {
  pending: ['待核销', 'warn'],
  processing: ['处理中', 'warn'],
  succeeded: ['已核销', 'ok'],
  failed: ['失败', 'bad'],
  abandoned: ['不再补查', 'muted'],
};

function renderAccountPoints(points) {
  const enabled = Boolean(points && points.enabled);
  $('#quota-points-body').hidden = !enabled;
  $('#quota-points-refresh').hidden = !enabled;
  $('#quota-points-note').textContent = enabled
    ? '只读：余额在支付宝一侧，扣减由即刻收完成。'
    : '这个实例没有开通积分收款。';
  if (!enabled) return;
  $('#quota-points-remaining').textContent = points.remaining == null
    ? '还没有同步' : number.format(points.remaining);
  $('#quota-points-charged').textContent = number.format(points.charged_today || 0);
  $('#quota-points-synced').textContent = points.synced_at ? moment(points.synced_at) : '—';
  const body = $('#quota-points-charges');
  body.replaceChildren();
  const charges = points.charges || [];
  for (const charge of charges) {
    const [label, tone] = pointChargeStatus[charge.status] || [charge.status, 'muted'];
    body.append(el('tr', {},
      el('td', { class: 'nowrap' }, moment(charge.created_at) || charge.day),
      el('td', { class: 'numeric' }, number.format(charge.points)),
      el('td', { class: 'numeric' }, number.format(charge.billed_tokens)),
      el('td', {}, el('span', { class: 'badge ' + tone }, label))));
  }
  const table = body.closest('table');
  if (table) table.parentElement.hidden = charges.length === 0;
  $('#quota-points-empty').hidden = charges.length > 0;
}

// openQuota 先读单个账号，取得今天的已结算用量与积分视图再打开弹窗；列表里的额度
// 可能已经被另一次保存改过，打开时以服务端返回的覆盖值为准。
async function openQuota(account) {
  detailRequest?.abort();
  const current = new AbortController();
  detailRequest = current;
  try {
    const detail = await api('GET', '/accounts/' + encodeURIComponent(account.id), null, current.signal);
    if (current.signal.aborted || $('#tab-accounts').hidden) return;
    accountQuotaAccount = detail;
    const form = $('#quota-form');
    form.reset();
    form.elements.daily_tokens.value = detail.quota.daily_tokens_override ?? '';
    form.elements.note.value = detail.quota.note || '';
    $('#quota-account').textContent = `${accountLabel(detail)}（${detail.id}）`;
    $('#quota-usage-day').textContent = detail.usage?.day || '';
    $('#quota-identities').replaceChildren(...detail.identities.map((identity) =>
      el('li', {}, identity.identifier, el('span', { class: 'badge ' + (identity.verified ? 'ok' : 'muted') },
        identity.verified ? '已验证' : '未验证'))));
    $('#quota-chat-used').textContent = `${number.format(detail.usage?.chat_tokens || 0)} Token`;
    $('#quota-embedding-used').textContent = `${number.format(detail.usage?.embedding_tokens || 0)} Token`;
    $('#quota-daily-default').textContent = accountLimitText(detail.quota.default_daily_tokens);
    $('#quota-updated').textContent = detail.quota.updated_at ? '最近保存 ' + moment(detail.quota.updated_at) : '';
    renderAccountPoints(detail.points);
    $('#quota-reset').disabled = detail.quota.daily_tokens_override == null && !detail.quota.note;
    clearError('quota-error');
    markClean(form);
    $('#quota-dialog').showModal();
  } catch (err) {
    if (!current.signal.aborted) toast(err.message);
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
  try {
    daily = quotaInput(form, 'daily_tokens');
  } catch (err) {
    showError('quota-error', err.message);
    return;
  }
  const note = form.elements.note.value.trim();
  await runSave($('#quota-save'), async () => {
    const saved = await api('PUT', '/accounts/' + encodeURIComponent(accountQuotaAccount.id) + '/quota',
      { daily_tokens: daily, note });
    const index = state.accounts.findIndex((item) => item.id === saved.id);
    if (index >= 0) state.accounts[index] = saved;
    renderAccounts();
    $('#quota-dialog').close();
    toast('额度已保存，下一次模型请求生效。');
  }, 'quota-error');
});

$('#quota-points-refresh').addEventListener('click', async () => {
  if (!accountQuotaAccount) return;
  const button = $('#quota-points-refresh');
  if (button.disabled) return;
  const account = accountQuotaAccount;
  const label = button.textContent;
  button.disabled = true;
  button.textContent = '刷新中…';
  clearError('quota-error');
  try {
    const points = await api('POST',
      '/accounts/' + encodeURIComponent(account.id) + '/points/refresh');
    if (accountQuotaAccount !== account || !$('#quota-dialog').open) return;
    account.points = points;
    renderAccountPoints(points);
    toast('余额已刷新。');
  } catch (err) {
    if (accountQuotaAccount === account && $('#quota-dialog').open) showError('quota-error', err.message);
  } finally {
    button.disabled = false;
    button.textContent = label;
  }
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


function openAccountSearch(userID) {
  clearTimeout(accountSearchTimer);
  state.accountQuery = userID;
  state.accountOffset = 0;
  $('#account-search').value = userID;
  loadAccounts();
}

$('#quota-key-usage').addEventListener('click', async () => {
  if (!accountQuotaAccount) return;
  const id = accountQuotaAccount.id;
  await requestClose('quota-dialog');
  if (!$('#quota-dialog').open && accountQuotaAccount?.id === id) openTab('key-usage', id);
});

function resetAccounts() {
  accountRequest?.abort();
  detailRequest?.abort();
  clearTimeout(accountSearchTimer);
  state.accounts = [];
  state.accountTotal = 0;
  state.accountOffset = 0;
  state.accountQuery = '';
  $('#account-search').value = '';
  accountQuotaAccount = null;
  accountDeleteAccount = null;
}

export { loadAccounts, resetAccounts, openAccountSearch };
