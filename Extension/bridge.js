// Extension-world content script: relays between page-volume.js (page world) and background.js.
(() => {
  const api = globalThis.browser ?? globalThis.chrome;
  let gain = 1;

  const sendGain = () =>
    document.dispatchEvent(new CustomEvent("appmixer:gain", { detail: String(gain) }));

  document.addEventListener("appmixer:ready", sendGain);

  // Chrome already ran page-volume.js in the page world. Safari didn't, so add it as a page script.
  if (!document.documentElement.hasAttribute("data-appmixer-tabs")) {
    const script = document.createElement("script");
    script.src = api.runtime.getURL("page-volume.js");
    script.onload = () => script.remove();
    (document.head || document.documentElement).appendChild(script);
  }

  document.addEventListener("appmixer:state", (e) => {
    let playing = false;
    try { playing = !!JSON.parse(e.detail).playing; } catch (_) {}
    api.runtime.sendMessage({ type: "state", playing }).catch(() => {});
  });

  api.runtime.onMessage.addListener((msg) => {
    if (msg?.type === "gain" && typeof msg.gain === "number") {
      gain = msg.gain;
      sendGain();
    }
  });

  api.runtime.sendMessage({ type: "hello" })
    .then((reply) => {
      if (reply && typeof reply.gain === "number") {
        gain = reply.gain;
        sendGain();
      }
    })
    .catch(() => {});
})();
