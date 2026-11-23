// Runs in the page's own JavaScript world so it can scale every sound the page makes.
// - <audio>/<video>: the page keeps seeing the volume it set; the element really plays at volume × tab gain.
// - Web Audio: each AudioContext's `destination` is routed through a gain node.
// Talks to bridge.js (extension world) through DOM events carrying strings.
(() => {
  // Browsers without `"world": "MAIN"` support (Safari) run this file in the extension's world,
  // where patching does nothing. Bail out there; bridge.js injects us into the page instead.
  const ext = globalThis.browser ?? globalThis.chrome;
  if (ext?.runtime?.id) return;

  const root = document.documentElement;
  if (window.__appMixerTabVolume || root?.hasAttribute("data-appmixer-tabs")) return;
  window.__appMixerTabVolume = true;
  root?.setAttribute("data-appmixer-tabs", "");

  let gain = 1;
  const pageVolume = new WeakMap(); // element -> volume the page asked for
  const elements = new Set();       // WeakRef<HTMLMediaElement>
  const contexts = new Set();       // WeakRef<AudioContext>
  const contextGain = new WeakMap(); // context -> GainNode

  // ---- Media elements ----
  const volumeDesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "volume");
  const realGet = volumeDesc.get;
  const realSet = volumeDesc.set;

  const track = (el) => {
    if (!pageVolume.has(el)) {
      pageVolume.set(el, realGet.call(el));
      elements.add(new WeakRef(el));
    }
  };
  const apply = (el) => {
    track(el);
    try { realSet.call(el, Math.max(0, Math.min(1, pageVolume.get(el) * gain))); } catch (_) {}
  };

  Object.defineProperty(HTMLMediaElement.prototype, "volume", {
    configurable: true,
    enumerable: volumeDesc.enumerable,
    get() { return pageVolume.has(this) ? pageVolume.get(this) : realGet.call(this); },
    set(value) {
      const v = Number(value);
      if (!(v >= 0 && v <= 1)) return realSet.call(this, value); // keep the browser's own error
      track(this);
      pageVolume.set(this, v);
      apply(this);
    },
  });

  const realPlay = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function (...args) {
    apply(this);
    return realPlay.apply(this, args);
  };

  // Autoplaying elements never call play(); catch them by event.
  for (const type of ["play", "playing", "pause", "ended", "emptied"]) {
    document.addEventListener(type, (e) => {
      if (e.target instanceof HTMLMediaElement) {
        if (type === "play" || type === "playing") apply(e.target);
        report();
      }
    }, true);
  }

  // ---- Web Audio ----
  const destDesc = Object.getOwnPropertyDescriptor(BaseAudioContext.prototype, "destination");
  Object.defineProperty(BaseAudioContext.prototype, "destination", {
    configurable: true,
    enumerable: destDesc.enumerable,
    get() {
      const real = destDesc.get.call(this);
      if (typeof OfflineAudioContext !== "undefined" && this instanceof OfflineAudioContext) return real;
      let node = contextGain.get(this);
      if (!node) {
        node = this.createGain();
        node.gain.value = gain;
        node.connect(real);
        Object.defineProperty(node, "maxChannelCount", { get: () => real.maxChannelCount });
        contextGain.set(this, node);
        contexts.add(new WeakRef(this));
        this.addEventListener?.("statechange", report);
      }
      return node;
    },
  });

  // ---- State ----
  const isPlaying = () => {
    for (const ref of elements) {
      const el = ref.deref();
      if (!el) { elements.delete(ref); continue; }
      if (!el.paused && !el.ended && el.readyState > 2) return true;
    }
    for (const ref of contexts) {
      const ctx = ref.deref();
      if (!ctx) { contexts.delete(ref); continue; }
      if (ctx.state === "running") return true;
    }
    return false;
  };

  let lastReported = null;
  function report() {
    const playing = isPlaying();
    if (playing || playing !== lastReported) {
      lastReported = playing;
      document.dispatchEvent(new CustomEvent("appmixer:state", { detail: JSON.stringify({ playing }) }));
    }
  }
  setInterval(report, 1000);

  document.addEventListener("appmixer:gain", (e) => {
    const g = Number(e.detail);
    if (!(g >= 0 && g <= 1)) return;
    gain = g;
    for (const ref of elements) {
      const el = ref.deref();
      if (el) apply(el); else elements.delete(ref);
    }
    for (const ref of contexts) {
      const ctx = ref.deref();
      const node = ctx && contextGain.get(ctx);
      if (node) node.gain.setTargetAtTime(gain, ctx.currentTime, 0.015);
      else contexts.delete(ref);
    }
  });

  document.dispatchEvent(new CustomEvent("appmixer:ready"));
})();
