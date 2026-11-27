import { $, api, el, number, moment, toast, askConfirm, showError, clearError } from './shared.js';

const state = { feedback: [], feedbackTotal: 0, feedbackLimit: 20, feedbackOffset: 0, feedbackQuery: '' };
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


function resetFeedback() {
  feedbackRequest?.abort();
  clearTimeout(feedbackSearchTimer);
  state.feedback = [];
  state.feedbackTotal = 0;
  state.feedbackOffset = 0;
  state.feedbackQuery = '';
  $('#feedback-search').value = '';
  feedbackDetail = null;
}

export { loadFeedback, resetFeedback };
