// Keeps each tab's volume, pushes it into the tab, and syncs with the AUDIX menu bar app
// over http://127.0.0.1:47300 (if it's running).
const api = globalThis.browser ?? globalThis.chrome;

const BRIDGE_URL = "http://127.0.0.1:47300/sync";
const BROWSER = navigator.brave ? "com.brave.Browser"
  : navigator.userAgent.includes("Edg/") ? "com.microsoft.edgemac"
  : navigator.userAgent.includes("Chrome/") ? "com.google.Chrome"
  : "com.apple.Safari";

let settings = {};      // tabId -> { volume, muted }   (only non-default)
const playingAt = {};   // tabId -> last time a frame reported playing
const ready = api.storage.local.get("tabSettings").then((r) => { settings = r.tabSettings || {}; });

const effectiveGain = (id) => {
  const s = settings[id];
  return !s ? 1 : s.muted ? 0 : s.volume;
};

async function setTab(id, { volume, muted }) {
  await ready;
  volume = Math.max(0, Math.min(1, Number(volume)));
  if (volume >= 0.995 && !muted) delete settings[id];
  else settings[id] = { volume, muted: !!muted };
  api.storage.local.set({ tabSettings: settings });
  api.tabs.sendMessage(Number(id), { type: "gain", gain: effectiveGain(id) }).catch(() => {});
}

async function listTabs() {
  await ready;
  const now = Date.now();
  const ids = new Set(Object.keys(settings));
  for (const [id, t] of Object.entries(playingAt)) if (now - t < 3000) ids.add(id);

  const tabs = [];
  for (const id of ids) {
    try {
      const tab = await api.tabs.get(Number(id));
      const s = settings[id] || { volume: 1, muted: false };
      let host = null;
      try { host = new URL(tab.url).hostname; } catch (_) {}
      tabs.push({
        id: Number(id),
        title: tab.title || host || "Tab",
        host,
        favicon: /^https?:/.test(tab.favIconUrl || "") ? tab.favIconUrl : null,
        playing: now - (playingAt[id] || 0) < 3000,
        volume: s.volume,
        muted: s.muted,
      });
    } catch (_) {
      delete settings[id]; // tab closed
      delete playingAt[id];
    }
  }
  return tabs.sort((a, b) => a.id - b.id);
}

let syncing = false;
let lastSync = 0;
async function sync() {
  if (syncing || Date.now() - lastSync < 400) return;
  syncing = true;
  lastSync = Date.now();
  try {
    const tabs = await listTabs();
    const res = await fetch(BRIDGE_URL, {
      method: "POST",
      headers: { "Content-Type": "text/plain" },
      body: JSON.stringify({ browser: BROWSER, tabs }),
    });
    const { commands = {} } = await res.json();
    for (const [id, cmd] of Object.entries(commands)) await setTab(id, cmd);
  } catch (_) {
    // AUDIX not running — the popup still works on its own.
  } finally {
    syncing = false;
  }
}
setInterval(sync, 1000);

api.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  const tabId = sender.tab?.id;
  switch (msg?.type) {
    case "hello":
      ready.then(() => sendResponse({ gain: tabId == null ? 1 : effectiveGain(tabId) }));
      return true;
    case "state":
      if (tabId != null && msg.playing) playingAt[tabId] = Date.now();
      sync();
      return false;
    case "popup:list":
      listTabs().then(sendResponse);
      return true;
    case "popup:set":
      setTab(msg.id, msg).then(() => { sync(); sendResponse(true); });
      return true;
  }
  return false;
});

api.tabs.onRemoved.addListener((id) => {
  delete playingAt[id];
  if (settings[id]) {
    delete settings[id];
    api.storage.local.set({ tabSettings: settings });
  }
});
