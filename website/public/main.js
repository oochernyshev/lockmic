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

  // ── Split-flap flip counters ─────────────────────────────────────────
  const prefersReducedMotion =
    typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;

  const formatCount = (n) => {
    const v = typeof n === "number" && Number.isFinite(n) ? Math.max(0, Math.floor(n)) : 0;
    return new Intl.NumberFormat("en-US").format(v);
  };

  /** Build / update a flip-counter element to show `value`. */
  const setFlipValue = (root, value, { animate = true } = {}) => {
    if (!root) return;
    const next = Math.max(0, Math.floor(Number(value) || 0));
    const nextStr = formatCount(next); // e.g. "1,397"
    const prevStr = root.dataset.valueFormatted || "";
    root.dataset.value = String(next);
    root.dataset.valueFormatted = nextStr;
    root.setAttribute("aria-label", nextStr);

    const reduce = prefersReducedMotion || !animate;
    const chars = nextStr.split("");
    const prevChars = prevStr ? prevStr.split("") : [];

    // Rebuild structure when length changes
    if (root.childElementCount !== chars.length) {
      root.textContent = "";
      chars.forEach((ch) => {
        if (ch === ",") {
          const comma = document.createElement("span");
          comma.className = "flip-digit is-comma";
          comma.textContent = ",";
          comma.setAttribute("aria-hidden", "true");
          root.appendChild(comma);
          return;
        }
        const digit = document.createElement("span");
        digit.className = "flip-digit";
        digit.setAttribute("aria-hidden", "true");
        digit.innerHTML = `
          <span class="flip-card">
            <span class="flip-top" data-digit="${ch}"></span>
            <span class="flip-bottom" data-digit="${ch}"></span>
            <span class="flip-back-top" data-digit="${ch}"></span>
            <span class="flip-back-bottom" data-digit="${ch}"></span>
          </span>`;
        root.appendChild(digit);
      });
      return;
    }

    // Same structure — flip digits that changed (right-to-left cascade)
    const children = Array.from(root.children);
    let delay = 0;
    for (let i = children.length - 1; i >= 0; i--) {
      const el = children[i];
      if (el.classList.contains("is-comma")) continue;
      const ch = chars[i];
      const oldCh = prevChars[i];
      const top = el.querySelector(".flip-top");
      const bottom = el.querySelector(".flip-bottom");
      const backTop = el.querySelector(".flip-back-top");
      const backBottom = el.querySelector(".flip-back-bottom");
      if (!top || !bottom || !backTop || !backBottom) continue;

      if (reduce || oldCh === ch || oldCh == null) {
        top.dataset.digit = ch;
        bottom.dataset.digit = ch;
        backTop.dataset.digit = ch;
        backBottom.dataset.digit = ch;
        continue;
      }

      // Prepare: current on top/bottom, new on back faces
      top.dataset.digit = oldCh;
      bottom.dataset.digit = oldCh;
      backTop.dataset.digit = ch;
      backBottom.dataset.digit = ch;

      const runFlip = () => {
        el.classList.remove("flipping");
        // force reflow
        void el.offsetWidth;
        el.classList.add("flipping");
        const done = () => {
          top.dataset.digit = ch;
          bottom.dataset.digit = ch;
          backTop.dataset.digit = ch;
          backBottom.dataset.digit = ch;
          el.classList.remove("flipping");
          el.removeEventListener("animationend", onEnd);
        };
        const onEnd = (e) => {
          if (e.animationName === "flipBottom" || e.target === backBottom) done();
        };
        el.addEventListener("animationend", onEnd);
        // fallback
        setTimeout(done, 500);
      };

      setTimeout(runFlip, delay);
      delay += 70;
    }
  };

  // ── Votes ───────────────────────────────────────────────────────────
  const likeBtn = document.getElementById("voteLike");
  const dislikeBtn = document.getElementById("voteDislike");
  const likeCountEl = document.getElementById("likeCount");
  const dislikeCountEl = document.getElementById("dislikeCount");
  const voteStatus = document.getElementById("voteStatus");

  if (likeBtn && dislikeBtn && likeCountEl && dislikeCountEl) {
    const VOTE_KEY = "lockmic_vote_v1";
    const NS = "lockmic-com";

    const setStatus = (msg) => {
      if (voteStatus) voteStatus.textContent = msg || "";
    };

    const seedOf = (el) => {
      const n = Number(el.getAttribute("data-seed"));
      return Number.isFinite(n) ? n : 0;
    };

    const showCount = (el, n, animate = true) => {
      const value = Math.max(0, Math.floor(n));
      const first = !el.dataset.valueFormatted;
      if (first && animate && !prefersReducedMotion) {
        // Build digit slots as zeros (same shape as final number), then flip into place
        const formatted = formatCount(value);
        const zeroStr = formatted.replace(/[0-9]/g, "0");
        el.dataset.valueFormatted = "";
        setFlipValue(el, 0, { animate: false });
        // Force same digit layout as target (including commas)
        el.textContent = "";
        el.dataset.valueFormatted = zeroStr;
        el.dataset.value = "0";
        zeroStr.split("").forEach((ch) => {
          if (ch === ",") {
            const comma = document.createElement("span");
            comma.className = "flip-digit is-comma";
            comma.textContent = ",";
            comma.setAttribute("aria-hidden", "true");
            el.appendChild(comma);
            return;
          }
          const digit = document.createElement("span");
          digit.className = "flip-digit";
          digit.setAttribute("aria-hidden", "true");
          digit.innerHTML = `
            <span class="flip-card">
              <span class="flip-top" data-digit="0"></span>
              <span class="flip-bottom" data-digit="0"></span>
              <span class="flip-back-top" data-digit="0"></span>
              <span class="flip-back-bottom" data-digit="0"></span>
            </span>`;
          el.appendChild(digit);
        });
        requestAnimationFrame(() => setFlipValue(el, value, { animate: true }));
        return;
      }
      setFlipValue(el, value, { animate });
    };

    // Immediate seed display
    showCount(likeCountEl, seedOf(likeCountEl), true);
    showCount(dislikeCountEl, seedOf(dislikeCountEl), true);

    const parseCount = (data) => {
      if (!data || typeof data !== "object") return null;
      if (data.code === 400 || data.code === "404") return null;
      if (typeof data.count === "number" && Number.isFinite(data.count)) return data.count;
      if (typeof data.value === "number" && Number.isFinite(data.value)) return data.value;
      return null;
    };

    const fetchCount = async (name, seed) => {
      try {
        const urls = [
          `https://api.counterapi.dev/v1/${NS}/${name}`,
          `https://api.counterapi.dev/v1/${NS}/${name}/`,
        ];
        for (const url of urls) {
          const r = await fetch(url, { method: "GET", mode: "cors", cache: "no-store" });
          const data = await r.json().catch(() => null);
          const n = parseCount(data);
          if (n != null) return n;
        }
      } catch (e) {
        console.warn("count fetch failed", name, e);
      }
      return seed;
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

    const refreshCounts = async () => {
      const likeSeed = seedOf(likeCountEl);
      const dislikeSeed = seedOf(dislikeCountEl);
      const [likes, dislikes] = await Promise.all([
        fetchCount("likes", likeSeed),
        fetchCount("dislikes", dislikeSeed),
      ]);
      showCount(likeCountEl, Math.max(likes, likeSeed), true);
      showCount(dislikeCountEl, Math.max(dislikes, dislikeSeed), true);
    };

    const existing = localStorage.getItem(VOTE_KEY);
    if (existing === "like" || existing === "dislike") applyLocalVote(existing);

    refreshCounts();

    const castVote = async (choice) => {
      if (localStorage.getItem(VOTE_KEY)) return;
      const name = choice === "like" ? "likes" : "dislikes";
      const el = choice === "like" ? likeCountEl : dislikeCountEl;
      likeBtn.disabled = true;
      dislikeBtn.disabled = true;
      setStatus("Saving…");

      try {
        const urls = [
          `https://api.counterapi.dev/v1/${NS}/${name}/up`,
          `https://api.counterapi.dev/v1/${NS}/${name}/up/`,
        ];
        let data = null;
        let ok = false;
        for (const url of urls) {
          const r = await fetch(url, { method: "GET", mode: "cors", cache: "no-store" });
          data = await r.json().catch(() => null);
          if (r.ok && parseCount(data) != null) {
            ok = true;
            break;
          }
        }
        if (!ok) throw new Error("vote request failed");

        localStorage.setItem(VOTE_KEY, choice);
        const n = parseCount(data);
        if (n != null) showCount(el, Math.max(n, seedOf(el)), true);
        applyLocalVote(choice);
        refreshCounts();
      } catch (err) {
        console.warn("vote failed", err);
        likeBtn.disabled = false;
        dislikeBtn.disabled = false;
        setStatus("Could not save vote. Try again later.");
      }
    };

    likeBtn.addEventListener("click", () => castVote("like"));
    dislikeBtn.addEventListener("click", () => castVote("dislike"));
  }
})();
