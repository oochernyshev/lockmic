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
      // Same-tab navigation → browser downloads the binary from GitHub
      dmgLink.removeAttribute("target");
    };

    // Fallback already set in HTML (versioned asset URL).
    // Prefer whatever is on the latest GitHub Release.
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
})();
