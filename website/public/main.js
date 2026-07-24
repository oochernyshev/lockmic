(() => {
  "use strict";

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
  // Vote UI updates only after /up succeeds and a follow-up GET confirms.
  const likeBtn = document.getElementById("voteLike");
  const dislikeBtn = document.getElementById("voteDislike");
  const likeCountEl = document.getElementById("likeCount");
  const dislikeCountEl = document.getElementById("dislikeCount");
  const voteStatus = document.getElementById("voteStatus");

  if (likeBtn && dislikeBtn && likeCountEl && dislikeCountEl) {
    const VOTE_KEY = "lockmic_vote_v1";
    const NS = "lockmic-com";

    const known = { likes: null, dislikes: null };
    let countsReady = false;

    const setStatus = (msg) => {
      if (voteStatus) voteStatus.textContent = msg || "";
    };

    const setCountLoading = (el, label) => {
      el.classList.add("is-loading");
      el.classList.remove("is-empty");
      el.removeAttribute("data-value");
      el.removeAttribute("data-value-formatted");
      delete el.dataset.valueFormatted;
      delete el.dataset.value;
      el.setAttribute("aria-busy", "true");
      el.setAttribute("aria-label", label);
      el.innerHTML = '<span class="rate-count-loading" aria-hidden="true"></span>';
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

    const showCount = (el, key, n, animate = true) => {
      const incoming = Math.max(0, Math.floor(Number(n) || 0));
      // Never drop below a value already shown this session (stale GET after /up)
      const prev = known[key];
      const value = prev == null ? incoming : Math.max(prev, incoming);
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

    // Trailing slash only — without it the API 301/404s and wastes rate limit
    const apiGet = (name) =>
      `https://api.counterapi.dev/v1/${encodeURIComponent(NS)}/${encodeURIComponent(name)}/?_=${Date.now()}`;
    const apiUp = (name) =>
      `https://api.counterapi.dev/v1/${encodeURIComponent(NS)}/${encodeURIComponent(name)}/up/?_=${Date.now()}`;

    const fetchCount = async (name) => {
      try {
        const r = await fetch(apiGet(name), { method: "GET", mode: "cors", cache: "no-store" });
        const data = await r.json().catch(() => null);
        return parseCount(data);
      } catch (e) {
        console.warn("count fetch failed", name, e);
        return null;
      }
    };

    const applyLocalVote = (choice) => {
      likeBtn.classList.toggle("is-selected", choice === "like");
      dislikeBtn.classList.toggle("is-selected", choice === "dislike");
      likeBtn.setAttribute("aria-pressed", choice === "like" ? "true" : "false");
      dislikeBtn.setAttribute("aria-pressed", choice === "dislike" ? "true" : "false");
      if (choice) {
        likeBtn.disabled = true;
        dislikeBtn.disabled = true;
        setStatus(choice === "like" ? "Thanks — you liked LockMic." : "Thanks — you voted dislike.");
      }
    };

    const setVotingEnabled = (enabled) => {
      if (localStorage.getItem(VOTE_KEY)) return;
      likeBtn.disabled = !enabled;
      dislikeBtn.disabled = !enabled;
    };

    // Start: loading dots only (already in HTML; re-apply if script re-runs cleanly)
    setCountLoading(likeCountEl, "Loading likes");
    setCountLoading(dislikeCountEl, "Loading dislikes");
    setVotingEnabled(false);

    const refreshCounts = async () => {
      const [likes, dislikes] = await Promise.all([fetchCount("likes"), fetchCount("dislikes")]);

      if (likes != null) showCount(likeCountEl, "likes", likes, true);
      else if (known.likes == null) setCountUnavailable(likeCountEl, "Likes unavailable");

      if (dislikes != null) showCount(dislikeCountEl, "dislikes", dislikes, true);
      else if (known.dislikes == null) setCountUnavailable(dislikeCountEl, "Dislikes unavailable");

      countsReady = known.likes != null || known.dislikes != null;
      setVotingEnabled(countsReady);
    };

    const existing = localStorage.getItem(VOTE_KEY);
    if (existing === "like" || existing === "dislike") applyLocalVote(existing);

    refreshCounts();

    const castVote = async (choice) => {
      if (localStorage.getItem(VOTE_KEY) || !countsReady) return;
      const name = choice === "like" ? "likes" : "dislikes";
      const el = choice === "like" ? likeCountEl : dislikeCountEl;
      const key = name;
      if (known[key] == null) return;

      likeBtn.disabled = true;
      dislikeBtn.disabled = true;
      setStatus("Saving…");

      try {
        // 1) Confirm save via /up
        const r = await fetch(apiUp(name), { method: "GET", mode: "cors", cache: "no-store" });
        const data = await r.json().catch(() => null);
        const saved = parseCount(data);
        if (!r.ok || saved == null) throw new Error((data && data.message) || "vote failed");

        // 2) Confirm retrieval via fresh GET (do not bump the UI until both succeed)
        const retrieved = await fetchCount(name);
        if (retrieved == null) throw new Error("could not read updated count");

        // Use the higher of the two remote values (GET can lag behind /up)
        showCount(el, key, Math.max(saved, retrieved), true);
        localStorage.setItem(VOTE_KEY, choice);
        applyLocalVote(choice);
      } catch (err) {
        console.warn("vote failed", err);
        // Count unchanged — only re-enable if this browser has not already voted
        if (!localStorage.getItem(VOTE_KEY)) {
          likeBtn.disabled = false;
          dislikeBtn.disabled = false;
        }
        setStatus("Could not save vote. Try again later.");
      }
    };

    likeBtn.addEventListener("click", () => castVote("like"));
    dislikeBtn.addEventListener("click", () => castVote("dislike"));
  }
})();
