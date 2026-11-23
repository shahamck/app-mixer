const api = globalThis.browser ?? globalThis.chrome;
const list = document.getElementById("list");

function row(tab) {
  const el = document.createElement("div");
  el.className = "row" + (tab.playing ? "" : " idle");

  const icon = tab.favicon ? Object.assign(document.createElement("img"), { src: tab.favicon }) : document.createElement("span");
  if (!tab.favicon) icon.className = "dot";

  const title = Object.assign(document.createElement("span"), { className: "title", textContent: tab.title, title: tab.title });

  const slider = Object.assign(document.createElement("input"), { type: "range", min: 0, max: 100, step: 1, value: Math.round(tab.volume * 100) });
  slider.setAttribute("aria-label", `Volume for ${tab.title}`);
  const pct = Object.assign(document.createElement("span"), { className: "pct", textContent: slider.value + "%" });

  const mute = document.createElement("button");
  const paintMute = () => {
    mute.textContent = tab.muted ? "🔇" : "🔊";
    mute.className = tab.muted ? "on" : "";
    mute.setAttribute("aria-label", tab.muted ? "Unmute tab" : "Mute tab");
    slider.style.opacity = tab.muted ? 0.35 : 1;
  };
  paintMute();

  const send = () => api.runtime.sendMessage({ type: "popup:set", id: tab.id, volume: tab.volume, muted: tab.muted });
  slider.addEventListener("input", () => {
    tab.volume = slider.value / 100;
    if (tab.volume > 0) tab.muted = false;
    pct.textContent = slider.value + "%";
    paintMute();
    send();
  });
  mute.addEventListener("click", () => { tab.muted = !tab.muted; paintMute(); send(); });

  el.append(icon, title, slider, pct, mute);
  return el;
}

async function render() {
  const tabs = await api.runtime.sendMessage({ type: "popup:list" });
  list.replaceChildren(...(tabs?.length ? tabs.map(row)
    : [Object.assign(document.createElement("div"), { className: "empty", textContent: "No tabs are playing sound." })]));
}
render();
