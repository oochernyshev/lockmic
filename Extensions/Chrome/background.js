// Service worker: owns the Native Messaging port to LockMic and picks the active call tab.
const HOST = "com.lockmic.host";
let port = null;
const tabs = new Map(); // tabId -> { inCall, muted, at, focused }

function activeTab() {
  let best = null;
  for (const [id, t] of tabs) {
    if (!t.inCall) continue;
    if (!best || (t.focused && !best.t.focused) || (t.focused === best.t.focused && t.at > best.t.at)) {
      best = { id, t };
    }
  }
  return best;
}

function publish() {
  if (!port) return;
  const a = activeTab();
  port.postMessage(a ? { t: "state", inCall: true, muted: a.t.muted } : { t: "state", inCall: false });
}

function connect() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (_) { port = null; return; }
  port.onMessage.addListener((msg) => {
    if (msg.t !== "set") return;
    const a = activeTab();
    if (a) chrome.tabs.sendMessage(a.id, { type: "set", muted: msg.muted }).catch(() => {});
  });
  port.onDisconnect.addListener(() => { void chrome.runtime.lastError; port = null; }); // LockMic not running
  publish();
}

chrome.runtime.onMessage.addListener((msg, sender) => {
  if (msg.type !== "state" || !sender.tab) return;
  tabs.set(sender.tab.id, { inCall: msg.inCall, muted: msg.muted, focused: !!msg.focused, at: Date.now() });
  connect();
  publish();
});

chrome.tabs.onRemoved.addListener((id) => { tabs.delete(id); publish(); });
chrome.tabs.onActivated.addListener(({ tabId }) => {
  const t = tabs.get(tabId);
  if (t) { t.at = Date.now(); t.focused = true; }
  for (const [id, o] of tabs) if (id !== tabId) o.focused = false;
  publish();
});

// Reconnect after LockMic or the browser restarts; the host exits quietly when LockMic is down.
chrome.alarms.create("reconnect", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(() => { if (tabs.size) connect(); });
chrome.runtime.onStartup.addListener(connect);
