const $ = (sel) => document.querySelector(sel);
const state = {
  token: sessionStorage.getItem('zhixin-admin-token') || '',
  providers: [], models: [], upstreamNames: new Map(),
};

const number = new Intl.NumberFormat('zh-CN');
const percent = new Intl.NumberFormat('zh-CN', { style: 'percent', maximumFractionDigits: 1 });
const kindName = { chat: '聊天', embedding: '嵌入' };
const kindList = Object.keys(kindName);

function openTab(name, params) {
  document.dispatchEvent(new CustomEvent('admin:navigate', { detail: { name, params } }));
}

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
    if (unauthorized && token === state.token && !$('#app').hidden) {
      document.dispatchEvent(new CustomEvent('admin:unauthorized', { detail: message }));
    }
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

function moment(value) {
  const date = new Date(value);
  if (!value || Number.isNaN(date.getTime())) return '';
  return date.toLocaleString('zh-CN', { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' });
}

function routeShare(value) {
  return value > 0 && value < 0.001 ? '<0.1%' : percent.format(value);
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


export {
  $, state, el, api, toast, number, percent, kindName, kindList, moment, routeShare,
  openTab, markClean, requestClose, askConfirm, settleConfirm, showError, clearError, runSave,
};
