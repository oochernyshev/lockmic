(() => {
  "use strict";

  /** GA4 (same property as the macOS app: G-0ZRQC93T49). No-op if gtag missing. */
  const track = (name, params) => {
    if (typeof gtag !== "function") return;
    gtag("event", name, Object.assign({ platform: "web", product: "lockmic_website" }, params || {}));
  };

  const linkLocation = (el) => {
    if (!el || !el.closest) return "page";
    if (el.closest(".nav-drawer")) return "drawer";
    if (el.closest(".nav-links") || el.closest(".nav-inner")) return "nav";
    if (el.closest(".hero")) return "hero";
    if (el.closest(".cta-band")) return "cta";
    if (el.closest(".footer")) return "footer";
    if (el.closest("#download") || el.closest(".download-card")) return "download";
    if (el.closest("#rate")) return "rate";
    if (el.closest("#faq")) return "faq";
    return "page";
  };

  // In-page section links (#features, #download, …)
  document.querySelectorAll('a[href^="#"]').forEach((a) => {
    a.addEventListener("click", () => {
      const href = a.getAttribute("href") || "";
      const sectionId = href.replace(/^#/, "") || "top";
      if (!sectionId || sectionId === "main") return; // skip “Skip to content”
      track("section_click", {
        section_id: sectionId,
        link_text: (a.textContent || "").trim().slice(0, 48),
        link_location: linkLocation(a),
      });
    });
  });

  const nav = document.getElementById("nav");
  const toggle = document.getElementById("navToggle");
  const drawer = document.getElementById("navDrawer");

  const onScroll = () => {
    if (!nav) return;
    nav.classList.toggle("scrolled", window.scrollY > 8);
  };
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });

  if (toggle && drawer) {
    const setOpen = (open) => {
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
      toggle.setAttribute("aria-label", open ? "Close menu" : "Open menu");
      if (open) drawer.removeAttribute("hidden");
      else drawer.setAttribute("hidden", "");
    };
    toggle.addEventListener("click", () => {
      setOpen(toggle.getAttribute("aria-expanded") !== "true");
    });
    drawer.querySelectorAll("a").forEach((a) => {
      a.addEventListener("click", () => setOpen(false));
    });
  }

  const reveals = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("visible");
            io.unobserve(entry.target);
          }
        });
      },
      { rootMargin: "0px 0px -8% 0px", threshold: 0.08 }
    );
    reveals.forEach((el, i) => {
      el.style.transitionDelay = `${Math.min(i % 6, 5) * 40}ms`;
      io.observe(el);
    });
  } else {
    reveals.forEach((el) => el.classList.add("visible"));
  }

  // ── Hero HUD mute demo ──────────────────────────────────────────────
  // Click the floating HUD (or menu-bar mic) to toggle mute/unmute with
  // short Web Audio cues (inspired by macOS Tink / Pop feedback).
  // Icons match the app’s SF Symbol style: mic.fill / mic.slash.fill.
  const hudDemo = document.getElementById("hudDemo");
  const hudDemoMenubar = document.getElementById("hudDemoMenubar");
  const hudDemoLabel = document.getElementById("hudDemoLabel");
  const hudDemoIcon = document.getElementById("hudDemoIcon");

  if (hudDemo && hudDemoLabel && hudDemoIcon) {
    let muted = true;
    let audioCtx = null;

    // Filled glyphs (white) — same idea as SF Symbols mic.fill / mic.slash.fill
    const ICON_UNMUTED =
      '<svg viewBox="0 0 24 24" width="56" height="56" aria-hidden="true">' +
      '<path fill="currentColor" d="M12 14c1.66 0 3-1.34 3-3V5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3zm5-3h2c0 3.53-2.61 6.43-6 6.92V21h-2v-3.08C7.61 17.43 5 14.53 5 11h2c0 2.76 2.24 5 5 5s5-2.24 5-5z"/>' +
      "</svg>";

    const ICON_MUTED =
      '<svg viewBox="0 0 24 24" width="56" height="56" aria-hidden="true">' +
      '<path fill="currentColor" d="M19 11h-1.7c0 .74-.16 1.43-.43 2.05l1.23 1.23c.56-.98.9-2.09.9-3.28zm-4.02.17c0-.06.02-.11.02-.17V5c0-1.66-1.34-3-3-3S9 3.34 9 5v.18l5.98 5.99zM4.27 3 3 4.27l6.01 6.01V11c0 1.66 1.33 2.99 2.99 2.99.22 0 .44-.03.65-.08l1.66 1.66c-.71.33-1.5.52-2.31.52-2.76 0-5.3-2.1-5.3-5.1H5c0 3.41 2.72 6.23 6 6.72V21h2v-3.28c.91-.13 1.77-.45 2.54-.9L19.73 21 21 19.73 4.27 3z"/>' +
      "</svg>";

    const ensureAudio = () => {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return null;
      if (!audioCtx) audioCtx = new AC();
      if (audioCtx.state === "suspended") audioCtx.resume().catch(() => {});
      return audioCtx;
    };

    /** Short click cues — mute ≈ Tink, unmute ≈ Pop. */
    const playMuteCue = (nowMuted) => {
      const ctx = ensureAudio();
      if (!ctx) return;
      const t0 = ctx.currentTime;
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.connect(gain);
      gain.connect(ctx.destination);

      if (nowMuted) {
        // Higher metallic “tink”
        osc.type = "sine";
        osc.frequency.setValueAtTime(1900, t0);
        osc.frequency.exponentialRampToValueAtTime(980, t0 + 0.07);
        gain.gain.setValueAtTime(0.0001, t0);
        gain.gain.exponentialRampToValueAtTime(0.2, t0 + 0.008);
        gain.gain.exponentialRampToValueAtTime(0.0001, t0 + 0.11);
        osc.start(t0);
        osc.stop(t0 + 0.12);
      } else {
        // Softer lower “pop”
        osc.type = "sine";
        osc.frequency.setValueAtTime(480, t0);
        osc.frequency.exponentialRampToValueAtTime(160, t0 + 0.1);
        gain.gain.setValueAtTime(0.0001, t0);
        gain.gain.exponentialRampToValueAtTime(0.26, t0 + 0.006);
        gain.gain.exponentialRampToValueAtTime(0.0001, t0 + 0.13);
        osc.start(t0);
        osc.stop(t0 + 0.14);
      }
    };

    const setHudMuted = (next, { play = true } = {}) => {
      muted = !!next;
      hudDemo.classList.toggle("is-muted", muted);
      hudDemo.setAttribute("aria-pressed", muted ? "true" : "false");
      hudDemo.setAttribute(
        "aria-label",
        muted ? "Floating HUD demo: muted. Click to unmute." : "Floating HUD demo: unmuted. Click to mute."
      );
      hudDemoLabel.textContent = muted ? "Muted" : "Unmuted";
      // Replace icon entirely (avoids dual-SVG / [hidden] fights)
      hudDemoIcon.innerHTML = muted ? ICON_MUTED : ICON_UNMUTED;

      if (hudDemoMenubar) {
        hudDemoMenubar.classList.toggle("is-muted", muted);
        hudDemoMenubar.setAttribute(
          "aria-label",
          muted ? "Menu bar mute toggle demo: muted" : "Menu bar mute toggle demo: unmuted"
        );
      }

      if (play) {
        playMuteCue(muted);
        hudDemo.classList.remove("is-flash");
        // restart flash animation
        void hudDemo.offsetWidth;
        hudDemo.classList.add("is-flash");
      }
    };

    const toggleHud = () => setHudMuted(!muted, { play: true });

    hudDemo.addEventListener("click", toggleHud);
    if (hudDemoMenubar) hudDemoMenubar.addEventListener("click", toggleHud);

    // Initial paint (no sound)
    setHudMuted(true, { play: false });
  }

  document.querySelectorAll(".copy-btn").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const text = btn.getAttribute("data-copy") || "";
      try {
        await navigator.clipboard.writeText(text);
        const prev = btn.textContent;
        btn.textContent = "Copied";
        btn.classList.add("copied");
        setTimeout(() => {
          btn.textContent = prev;
          btn.classList.remove("copied");
        }, 1600);
      } catch {
        btn.textContent = "Failed";
        setTimeout(() => {
          btn.textContent = "Copy";
        }, 1600);
      }
    });
  });

  // Latest DMG
  const dmgLink = document.getElementById("downloadDmg");
  if (dmgLink) {
    dmgLink.addEventListener("click", () => {
      track("download_click", { link_id: "download_dmg", outbound: true });
    });

    const REPO = "oochernyshev/lockmic";
    fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: { Accept: "application/vnd.github+json" },
    })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
      .then((release) => {
        const assets = Array.isArray(release.assets) ? release.assets : [];
        const dmg = assets.find((a) => /\.dmg$/i.test(a.name));
        if (dmg && dmg.browser_download_url) {
          dmgLink.href = dmg.browser_download_url;
          dmgLink.setAttribute("download", dmg.name);
          dmgLink.removeAttribute("target");
          const title = document.querySelector(".download-card h2");
          const ver = (release.tag_name || "").replace(/^v/, "");
          if (title && ver) title.textContent = `Get LockMic ${ver}`;
        }
      })
      .catch(() => {});
  }

  // ── Odometer flip counters ──────────────────────────────────────────
  const prefersReducedMotion =
    typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;

  const formatCount = (n) => {
    const v = typeof n === "number" && Number.isFinite(n) ? Math.max(0, Math.floor(n)) : 0;
    return new Intl.NumberFormat("en-US").format(v);
  };

  const DIGITS = "0123456789";

  const buildDigit = (digitChar) => {
    const wrap = document.createElement("span");
    wrap.className = "odo-digit";
    wrap.setAttribute("aria-hidden", "true");
    const ribbon = document.createElement("span");
    ribbon.className = "odo-ribbon";
    for (let i = 0; i < DIGITS.length; i++) {
      const s = document.createElement("span");
      s.textContent = DIGITS[i];
      ribbon.appendChild(s);
    }
    // start at 0
    const d = Number(digitChar);
    ribbon.style.transform = `translateY(${-d * 10}%)`;
    ribbon.dataset.digit = String(d);
    wrap.appendChild(ribbon);
    return wrap;
  };

  const buildComma = () => {
    const comma = document.createElement("span");
    comma.className = "odo-digit is-comma";
    comma.textContent = ",";
    comma.setAttribute("aria-hidden", "true");
    return comma;
  };

  /** Render / animate odometer to `value`. */
  const setFlipValue = (root, value, { animate = true } = {}) => {
    if (!root) return;
    const next = Math.max(0, Math.floor(Number(value) || 0));
    const nextStr = formatCount(next);
    const prevStr = root.dataset.valueFormatted || "";
    root.dataset.value = String(next);
    root.dataset.valueFormatted = nextStr;
    root.setAttribute("aria-label", nextStr);

    const chars = nextStr.split("");
    const prevChars = prevStr ? prevStr.split("") : [];
    const reduce = prefersReducedMotion || !animate;

    // Rebuild when length / shape changes
    if (root.childElementCount !== chars.length) {
      root.textContent = "";
      chars.forEach((ch) => {
        root.appendChild(ch === "," ? buildComma() : buildDigit(ch === "," ? "0" : ch));
      });
      // set positions
      Array.from(root.children).forEach((child, i) => {
        if (child.classList.contains("is-comma")) return;
        const ribbon = child.querySelector(".odo-ribbon");
        const d = Number(chars[i]);
        if (!ribbon || !Number.isFinite(d)) return;
        ribbon.style.transition = reduce ? "none" : "";
        ribbon.style.transform = `translateY(${-d * 10}%)`;
        ribbon.dataset.digit = String(d);
      });
      return;
    }

    // Same shape — roll digits that changed (cascade from right)
    const children = Array.from(root.children);
    let delay = 0;
    for (let i = children.length - 1; i >= 0; i--) {
      const child = children[i];
      if (child.classList.contains("is-comma")) continue;
      const ch = chars[i];
      const d = Number(ch);
      if (!Number.isFinite(d)) continue;
      const ribbon = child.querySelector(".odo-ribbon");
      if (!ribbon) continue;
      const old = ribbon.dataset.digit;
      if (old === String(d) && prevStr) continue;

      const apply = () => {
        if (reduce) {
          ribbon.style.transition = "none";
          ribbon.style.transform = `translateY(${-d * 10}%)`;
          ribbon.dataset.digit = String(d);
          return;
        }
        // Longer spin when jumping many steps (e.g. intro 0 → 9)
        const from = old != null ? Number(old) : 0;
        const dist = Math.abs(d - from);
        const ms = 450 + dist * 40;
        ribbon.style.transition = `transform ${ms}ms cubic-bezier(0.2, 0.85, 0.25, 1)`;
        ribbon.style.transform = `translateY(${-d * 10}%)`;
        ribbon.dataset.digit = String(d);
      };

      if (delay === 0 || reduce) apply();
      else setTimeout(apply, delay);
      delay += 55;
    }
  };

  // ── Votes ───────────────────────────────────────────────────────────
  // Counts come only from CounterAPI. Loading indicator until first fetch.
  // Vote UI updates only after /up (or /down on remove) and a follow-up GET.
  const likeBtn = document.getElementById("voteLike");
  const dislikeBtn = document.getElementById("voteDislike");
  const likeCountEl = document.getElementById("likeCount");
  const dislikeCountEl = document.getElementById("dislikeCount");
  const voteStatus = document.getElementById("voteStatus");
  const removeBtn = document.getElementById("voteRemove");

  if (likeBtn && dislikeBtn && likeCountEl && dislikeCountEl) {
    // Opaque storage slot. Value is a fresh client-minted JWT each vote
    // (unique jti), not a fixed like/dislike string.
    // Not a security boundary: the signing material ships in this file.
    // Stops casual localStorage edits / makes values non-constant.
    const VOTE_KEY = "lm_c7a91e2b4f0d8e3a";
    // Client-only HMAC material (obfuscation, not auth)
    const VOTE_JWT_SECRET = "lm.v1.k.7f3c9a1e2b8d4f0a6c5e9b2d";
    const NS = "lockmic-com";

    const known = { likes: null, dislikes: null };
    let countsReady = false;
    let voteBusy = false;
    /** @type {"like"|"dislike"|null} */
    let localChoice = null;

    const te = new TextEncoder();
    const td = new TextDecoder();

    const bytesToB64url = (bytes) => {
      const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
      let bin = "";
      for (let i = 0; i < arr.length; i++) bin += String.fromCharCode(arr[i]);
      return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
    };

    const strToB64url = (str) => bytesToB64url(te.encode(str));

    const b64urlToBytes = (s) => {
      const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
      const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + pad;
      const bin = atob(b64);
      const out = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
      return out;
    };

    const b64urlToStr = (s) => td.decode(b64urlToBytes(s));

    const randomJti = () => {
      const buf = new Uint8Array(16);
      if (globalThis.crypto && crypto.getRandomValues) crypto.getRandomValues(buf);
      else for (let i = 0; i < buf.length; i++) buf[i] = (Math.random() * 256) | 0;
      return Array.from(buf, (b) => b.toString(16).padStart(2, "0")).join("");
    };

    let hmacKeyPromise = null;
    const getHmacKey = () => {
      if (!hmacKeyPromise) {
        if (!globalThis.crypto || !crypto.subtle) {
          hmacKeyPromise = Promise.reject(new Error("no WebCrypto"));
        } else {
          hmacKeyPromise = crypto.subtle.importKey(
            "raw",
            te.encode(VOTE_JWT_SECRET),
            { name: "HMAC", hash: "SHA-256" },
            false,
            ["sign", "verify"]
          );
        }
      }
      return hmacKeyPromise;
    };

    /** HS256 JWT: header.payload.sig — payload { v: 0|1, iat, jti } */
    const mintVoteJwt = async (choice) => {
      if (choice !== "like" && choice !== "dislike") throw new Error("bad choice");
      const header = strToB64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
      const payload = strToB64url(
        JSON.stringify({
          v: choice === "like" ? 1 : 0,
          iat: Math.floor(Date.now() / 1000),
          jti: randomJti(),
        })
      );
      const data = `${header}.${payload}`;
      const key = await getHmacKey();
      const sig = await crypto.subtle.sign("HMAC", key, te.encode(data));
      return `${data}.${bytesToB64url(sig)}`;
    };

    const parseVoteJwt = async (token) => {
      if (typeof token !== "string") return null;
      const parts = token.split(".");
      if (parts.length !== 3) return null;
      try {
        const [h, p, s] = parts;
        const key = await getHmacKey();
        const ok = await crypto.subtle.verify("HMAC", key, b64urlToBytes(s), te.encode(`${h}.${p}`));
        if (!ok) return null;
        const claims = JSON.parse(b64urlToStr(p));
        if (claims.v === 1) return "like";
        if (claims.v === 0) return "dislike";
        return null;
      } catch {
        return null;
      }
    };

    const readStoredVote = async () => {
      try {
        const raw = localStorage.getItem(VOTE_KEY);
        if (!raw) return null;
        return parseVoteJwt(raw);
      } catch {
        return null;
      }
    };

    const writeStoredVote = async (choice) => {
      if (choice !== "like" && choice !== "dislike") return;
      try {
        localStorage.setItem(VOTE_KEY, await mintVoteJwt(choice));
      } catch {
        /* ignore quota / private mode / crypto */
      }
    };

    const clearStoredVote = () => {
      try {
        localStorage.removeItem(VOTE_KEY);
      } catch {
        /* ignore */
      }
    };

    const setStatus = (msg) => {
      if (voteStatus) voteStatus.textContent = msg || "";
    };

    const setRemoveVisible = (visible) => {
      if (!removeBtn) return;
      if (visible) removeBtn.removeAttribute("hidden");
      else removeBtn.setAttribute("hidden", "");
    };

    const skeletonHtml = (digits) => {
      const cells = Array.from({ length: digits }, () => '<span class="rate-skel-digit"></span>').join("");
      return `<span class="rate-count-skeleton" aria-hidden="true">${cells}</span>`;
    };

    const setCountLoading = (el, label, digits = 4) => {
      el.classList.add("is-loading");
      el.classList.remove("is-empty");
      el.removeAttribute("data-value");
      el.removeAttribute("data-value-formatted");
      delete el.dataset.valueFormatted;
      delete el.dataset.value;
      el.setAttribute("aria-busy", "true");
      el.setAttribute("aria-label", label);
      el.innerHTML = skeletonHtml(digits);
    };

    const setCountUnavailable = (el, label) => {
      el.classList.remove("is-loading");
      el.classList.add("is-empty");
      el.removeAttribute("aria-busy");
      el.setAttribute("aria-label", label);
      el.textContent = "—";
      delete el.dataset.valueFormatted;
      delete el.dataset.value;
    };

    // force: trust remote even if lower (used after /down remove)
    const showCount = (el, key, n, animate = true, { force = false } = {}) => {
      const incoming = Math.max(0, Math.floor(Number(n) || 0));
      // Never drop below a value already shown this session (stale GET after /up)
      // unless force (intentional remove via /down).
      const prev = known[key];
      const value = force || prev == null ? incoming : Math.max(prev, incoming);
      known[key] = value;

      el.classList.remove("is-loading", "is-empty");
      el.removeAttribute("aria-busy");
      el.setAttribute("aria-label", formatCount(value));

      const first = !el.dataset.valueFormatted;
      if (first && animate && !prefersReducedMotion) {
        const formatted = formatCount(value);
        const zeroStr = formatted.replace(/[0-9]/g, "0");
        el.textContent = "";
        el.dataset.valueFormatted = zeroStr;
        el.dataset.value = "0";
        zeroStr.split("").forEach((ch) => {
          if (ch === ",") {
            const c = document.createElement("span");
            c.className = "odo-digit is-comma";
            c.textContent = ",";
            c.setAttribute("aria-hidden", "true");
            el.appendChild(c);
          } else {
            el.appendChild(buildDigit("0"));
          }
        });
        requestAnimationFrame(() => {
          requestAnimationFrame(() => setFlipValue(el, value, { animate: true }));
        });
        return;
      }
      setFlipValue(el, value, { animate });
    };

    const parseCount = (data) => {
      if (!data || typeof data !== "object") return null;
      if (data.code === 400 || data.code === 404 || data.code === "400" || data.code === "404") {
        return null;
      }
      if (typeof data.message === "string" && /not found/i.test(data.message)) return null;
      if (typeof data.count === "number" && Number.isFinite(data.count)) return data.count;
      if (typeof data.value === "number" && Number.isFinite(data.value)) return data.value;
      return null;
    };

    // CounterAPI is picky about trailing slashes (301s drop CORS headers in browsers):
    //   GET   → .../likes/       (slash required)
    //   /up   → .../likes/up     (no slash)
    //   /down → .../likes/down   (no slash)
    const apiGet = (name) =>
      `https://api.counterapi.dev/v1/${encodeURIComponent(NS)}/${encodeURIComponent(name)}/?_=${Date.now()}`;
    const apiUp = (name) =>
      `https://api.counterapi.dev/v1/${encodeURIComponent(NS)}/${encodeURIComponent(name)}/up?_=${Date.now()}`;
    const apiDown = (name) =>
      `https://api.counterapi.dev/v1/${encodeURIComponent(NS)}/${encodeURIComponent(name)}/down?_=${Date.now()}`;

    const fetchCount = async (name) => {
      try {
        const r = await fetch(apiGet(name), {
          method: "GET",
          mode: "cors",
          cache: "no-store",
          redirect: "error", // fail loud if we hit a slash redirect again
        });
        const data = await r.json().catch(() => null);
        return parseCount(data);
      } catch (e) {
        console.warn("count fetch failed", name, e);
        return null;
      }
    };

    const setVoteButtonsDisabled = (disabled) => {
      likeBtn.disabled = disabled;
      dislikeBtn.disabled = disabled;
    };

    const clearLocalVote = () => {
      likeBtn.classList.remove("is-selected");
      dislikeBtn.classList.remove("is-selected");
      likeBtn.setAttribute("aria-pressed", "false");
      dislikeBtn.setAttribute("aria-pressed", "false");
      setRemoveVisible(false);
      if (removeBtn) removeBtn.disabled = false;
    };

    const applyLocalVote = (choice) => {
      likeBtn.classList.toggle("is-selected", choice === "like");
      dislikeBtn.classList.toggle("is-selected", choice === "dislike");
      likeBtn.setAttribute("aria-pressed", choice === "like" ? "true" : "false");
      dislikeBtn.setAttribute("aria-pressed", choice === "dislike" ? "true" : "false");
      if (choice) {
        setVoteButtonsDisabled(true);
        setRemoveVisible(true);
        if (removeBtn) removeBtn.disabled = false;
        setStatus(choice === "like" ? "Thanks — you liked LockMic." : "Thanks — you voted dislike.");
      } else {
        clearLocalVote();
      }
    };

    const setVotingEnabled = (enabled) => {
      if (localChoice || voteBusy) return;
      setVoteButtonsDisabled(!enabled);
    };

    // Start: shimmering digit shells until CounterAPI responds
    setCountLoading(likeCountEl, "Loading likes", 4);
    setCountLoading(dislikeCountEl, "Loading dislikes", 2);
    setVotingEnabled(false);
    setRemoveVisible(false);

    const refreshCounts = async () => {
      const [likes, dislikes] = await Promise.all([fetchCount("likes"), fetchCount("dislikes")]);

      if (likes != null) showCount(likeCountEl, "likes", likes, true);
      else if (known.likes == null) setCountUnavailable(likeCountEl, "Likes unavailable");

      if (dislikes != null) showCount(dislikeCountEl, "dislikes", dislikes, true);
      else if (known.dislikes == null) setCountUnavailable(dislikeCountEl, "Dislikes unavailable");

      countsReady = known.likes != null || known.dislikes != null;
      setVotingEnabled(countsReady);
    };

    // Restore prior vote (JWT or legacy), then load public counts
    readStoredVote().then((existing) => {
      localChoice = existing;
      if (existing) applyLocalVote(existing);
      else setVotingEnabled(countsReady);
    });
    refreshCounts();

    const castVote = async (choice) => {
      if (voteBusy || localChoice || !countsReady) return;
      const name = choice === "like" ? "likes" : "dislikes";
      const el = choice === "like" ? likeCountEl : dislikeCountEl;
      const key = name;
      if (known[key] == null) return;

      voteBusy = true;
      setVoteButtonsDisabled(true);
      if (removeBtn) removeBtn.disabled = true;
      setStatus("Saving…");

      try {
        // 1) Confirm save via /up (final URL, no redirect — redirects break CORS)
        const r = await fetch(apiUp(name), {
          method: "GET",
          mode: "cors",
          cache: "no-store",
          redirect: "error",
        });
        const data = await r.json().catch(() => null);
        const saved = parseCount(data);
        if (!r.ok || saved == null) throw new Error((data && data.message) || "vote failed");

        // 2) Confirm retrieval via fresh GET (do not bump the UI until both succeed)
        const retrieved = await fetchCount(name);
        if (retrieved == null) throw new Error("could not read updated count");

        // Use the higher of the two remote values (GET can lag behind /up)
        showCount(el, key, Math.max(saved, retrieved), true);
        await writeStoredVote(choice);
        localChoice = choice;
        applyLocalVote(choice);
        track("vote", { vote_choice: choice, section_id: "rate" });
      } catch (err) {
        console.warn("vote failed", err);
        // Count unchanged — only re-enable if this browser has not already voted
        if (!localChoice) setVoteButtonsDisabled(false);
        setStatus("Could not save vote. Try again later.");
        track("vote_failed", { vote_choice: choice, section_id: "rate" });
      } finally {
        voteBusy = false;
      }
    };

    const removeVote = async () => {
      const choice = localChoice;
      if (voteBusy || !choice || !countsReady) return;
      const name = choice === "like" ? "likes" : "dislikes";
      const el = choice === "like" ? likeCountEl : dislikeCountEl;
      const key = name;
      if (known[key] == null) return;

      voteBusy = true;
      setVoteButtonsDisabled(true);
      if (removeBtn) removeBtn.disabled = true;
      setStatus("Removing…");

      try {
        const r = await fetch(apiDown(name), {
          method: "GET",
          mode: "cors",
          cache: "no-store",
          redirect: "error",
        });
        const data = await r.json().catch(() => null);
        const saved = parseCount(data);
        if (!r.ok || saved == null) throw new Error((data && data.message) || "remove failed");

        const retrieved = await fetchCount(name);
        if (retrieved == null) throw new Error("could not read updated count");

        // Prefer the lower of the two remotes after /down (GET can lag)
        showCount(el, key, Math.min(saved, retrieved), true, { force: true });
        clearStoredVote();
        localChoice = null;
        clearLocalVote();
        setStatus("Vote removed.");
        // Re-enable now — do not use setVotingEnabled while voteBusy is still true
        // (that helper no-ops when voteBusy, which left buttons stuck disabled).
        setVoteButtonsDisabled(false);
        track("vote_remove", { vote_choice: choice, section_id: "rate" });
      } catch (err) {
        console.warn("remove vote failed", err);
        // Keep selection; re-enable remove so the user can retry
        if (removeBtn) removeBtn.disabled = false;
        setStatus("Could not remove vote. Try again later.");
        track("vote_remove_failed", { vote_choice: choice, section_id: "rate" });
      } finally {
        voteBusy = false;
      }
    };

    likeBtn.addEventListener("click", () => castVote("like"));
    dislikeBtn.addEventListener("click", () => castVote("dislike"));
    if (removeBtn) removeBtn.addEventListener("click", () => removeVote());
  }
})();
