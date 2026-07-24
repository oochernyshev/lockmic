(() => {
  "use strict";

  const nav = document.getElementById("nav");
  const toggle = document.getElementById("navToggle");
  const drawer = document.getElementById("navDrawer");

  // Sticky nav border on scroll
  const onScroll = () => {
    if (!nav) return;
    nav.classList.toggle("scrolled", window.scrollY > 8);
  };
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });

  // Mobile drawer
  if (toggle && drawer) {
    const setOpen = (open) => {
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
      toggle.setAttribute("aria-label", open ? "Close menu" : "Open menu");
      if (open) drawer.removeAttribute("hidden");
      else drawer.setAttribute("hidden", "");
    };

    toggle.addEventListener("click", () => {
      const open = toggle.getAttribute("aria-expanded") !== "true";
      setOpen(open);
    });

    drawer.querySelectorAll("a").forEach((a) => {
      a.addEventListener("click", () => setOpen(false));
    });
  }

  // Reveal on scroll
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

  // Copy brew command
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

  // Resolve latest .dmg asset so "Download DMG" starts a file download (not the releases page).
  const dmgLink = document.getElementById("downloadDmg");
  if (dmgLink) {
    const REPO = "oochernyshev/lockmic";
    const applyDmg = (url, name) => {
      dmgLink.href = url;
      dmgLink.setAttribute("download", name || "LockMic.dmg");
      dmgLink.removeAttribute("target");
    };

    fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: { Accept: "application/vnd.github+json" },
    })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
      .then((release) => {
        const assets = Array.isArray(release.assets) ? release.assets : [];
        const dmg =
          assets.find((a) => /\.dmg$/i.test(a.name)) ||
          assets.find((a) => /LockMic.*\.dmg/i.test(a.name));
        if (dmg && dmg.browser_download_url) {
          applyDmg(dmg.browser_download_url, dmg.name);
          const title = document.querySelector(".download-card h2");
          const ver = (release.tag_name || "").replace(/^v/, "");
          if (title && ver) title.textContent = `Get LockMic ${ver}`;
        }
      })
      .catch(() => {
        /* keep static href from HTML */
      });
  }

  // ── Like / dislike ───────────────────────────────────────────────────
  // Firebase Hosting = static files only (no database).
  // Counts use free CounterAPI over HTTPS — no Firebase DB / no account.
  const likeBtn = document.getElementById("voteLike");
  const dislikeBtn = document.getElementById("voteDislike");
  const likeCountEl = document.getElementById("likeCount");
  const dislikeCountEl = document.getElementById("dislikeCount");
  const voteStatus = document.getElementById("voteStatus");

  if (likeBtn && dislikeBtn) {
    const VOTE_KEY = "lockmic_vote_v1";
    const NS = "lockmic-com";
    const counterUrl = (name, action) => {
      let path = `https://api.counterapi.dev/v1/${encodeURIComponent(NS)}/${encodeURIComponent(name)}/`;
      if (action) path += `${action}/`;
      return path;
    };

    const setStatus = (msg) => {
      if (voteStatus) voteStatus.textContent = msg || "";
    };

    const formatCount = (n) => {
      if (typeof n !== "number" || !Number.isFinite(n)) return "0";
      return new Intl.NumberFormat().format(Math.max(0, Math.floor(n)));
    };

    const parseCount = (data) => {
      if (data == null || data.code === 400) return 0;
      if (typeof data.count === "number") return data.count;
      if (typeof data.value === "number") return data.value;
      return 0;
    };

    const fetchCount = (name) =>
      fetch(counterUrl(name))
        .then((r) => r.json().catch(() => ({})))
        .then(parseCount)
        .catch(() => 0);

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

    const refreshCounts = () =>
      Promise.all([fetchCount("likes"), fetchCount("dislikes")]).then(([likes, dislikes]) => {
        if (likeCountEl) likeCountEl.textContent = formatCount(likes);
        if (dislikeCountEl) dislikeCountEl.textContent = formatCount(dislikes);
      });

    const existing = localStorage.getItem(VOTE_KEY);
    if (existing === "like" || existing === "dislike") {
      applyLocalVote(existing);
    }

    refreshCounts();

    const castVote = (choice) => {
      if (localStorage.getItem(VOTE_KEY)) return;
      const name = choice === "like" ? "likes" : "dislikes";
      likeBtn.disabled = true;
      dislikeBtn.disabled = true;
      setStatus("Saving…");
      fetch(counterUrl(name, "up"))
        .then((r) => r.json().then((data) => ({ ok: r.ok, data })))
        .then(({ ok, data }) => {
          if (!ok && data && data.code) throw new Error(data.message || "vote failed");
          localStorage.setItem(VOTE_KEY, choice);
          const el = choice === "like" ? likeCountEl : dislikeCountEl;
          if (el) el.textContent = formatCount(parseCount(data));
          applyLocalVote(choice);
          refreshCounts();
        })
        .catch((err) => {
          console.warn("vote failed", err);
          likeBtn.disabled = false;
          dislikeBtn.disabled = false;
          setStatus("Could not save vote. Try again later.");
        });
    };

    likeBtn.addEventListener("click", () => castVote("like"));
    dislikeBtn.addEventListener("click", () => castVote("dislike"));
  }
})();
