// Runs on meet.google.com only. Finds the microphone button by stable attributes,
// reports its mute state and presses it on command. No audio or page data leaves the page.
(() => {
  const MIC_LABEL = /microphone|mikrofon|micr[oó]fono|microfone|микрофон|マイク|마이크|麦克风|麦克風|mikrofonen/i;
  let lastSent = null;

  function micButton() {
    const buttons = [...document.querySelectorAll("button[data-is-muted], [role='button'][data-is-muted]")];
    if (!buttons.length) return null;
    const labelled = buttons.find((b) => MIC_LABEL.test(b.getAttribute("aria-label") || b.dataset.tooltip || ""));
    // Fallback if labels are localized in an unknown language: the mic precedes the camera.
    return labelled || buttons[0];
  }

  function snapshot() {
    const button = micButton();
    if (!button) return { inCall: false, muted: null };
    return { inCall: true, muted: button.getAttribute("data-is-muted") === "true" };
  }

  function report(force) {
    const s = snapshot();
    const key = `${s.inCall}:${s.muted}`;
    if (!force && key === lastSent) return;
    lastSent = key;
    try {
      chrome.runtime.sendMessage({ type: "state", ...s, focused: document.hasFocus() });
    } catch (_) { /* extension reloaded: page will be re-injected */ }
  }

  new MutationObserver(() => report(false)).observe(document.body, {
    subtree: true, childList: true, attributes: true, attributeFilter: ["data-is-muted", "aria-label"],
  });
  window.addEventListener("focus", () => report(true));
  setInterval(() => report(false), 1000); // safety net if Meet re-renders the toolbar
  window.addEventListener("pagehide", () => {
    try { chrome.runtime.sendMessage({ type: "state", inCall: false, muted: null }); } catch (_) {}
  });

  chrome.runtime.onMessage.addListener((msg) => {
    if (msg.type !== "set") return;
    const button = micButton();
    if (!button) return;
    const muted = button.getAttribute("data-is-muted") === "true";
    if (muted !== msg.muted) button.click();
  });

  report(true);
})();
