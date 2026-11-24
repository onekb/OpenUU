(() => {
  const SELF_HOST_PROMPT = `请帮我部署一套私有的 OpenUU 跨网寻址（Coord）与打洞中继（Relay）服务器。
开源仓库地址：https://github.com/onekb/OpenUU （请先拉取或阅读仓库下的 deploy/ 目录与 README.md）。

部署要求：
1. 云服务器方案请参考 \`deploy/docker-compose.yml\`、\`deploy/Dockerfile.coord\` 与 \`deploy/Caddyfile\`；零暴露公网 IP 方案请参考 \`deploy/cloudflare-worker\` 与 \`deploy/cloudflare-relay-worker\`（Cloudflare Workers + D1 + Tunnel）。
2. 先向我确认服务器 SSH 信息与解析好的 Coord / Relay 二级域名（或是否采用纯 IP 自签证书 / Cloudflare 方案）。
3. 自动完成容器构建启动、HTTPS 证书签发、端口放行（TCP 80/443，UDP 443/3478/7842）及中继鉴权 Bearer Token 配置，并验证 \`/health\` 接口返回正常。
4. 部署完成后，直接输出需要填入 OpenUU「网络与日志」页面的三项配置：设备码寻址 (Coord URL)、打洞与中继 (Relay URL)、中继鉴权 Token。`;

  // 1. Subtle footer server online status check
  async function checkHealth() {
    const el = document.getElementById("footer-health");
    const t0 = performance.now();
    try {
      const resp = await fetch("/health", { cache: "no-store" });
      if (!resp.ok) return;
      const data = await resp.json();
      const ms = Math.max(1, Math.round(performance.now() - t0));
      if (data && data.status === "ok" && el) {
        el.innerHTML = `<span class="live-dot"></span>连接服务运行正常 (${ms}ms)`;
      }
    } catch {
      // Quiet fallback
    }
  }

  // 2. End-to-End Choreographed Mac Desktop Stage
  function initDesktopStage() {
    const stageViewport = document.getElementById("mac-stage-viewport");
    const wallpaper = document.getElementById("mac-wallpaper");
    const activeApp = document.getElementById("mac-active-name");
    const connectedTag = document.getElementById("mac-connected-tag");
    const segs = document.querySelectorAll(".seg-item");
    const wins = document.querySelectorAll(".app-win[data-win]");
    const dockIcons = document.querySelectorAll(".dock-app[data-win]");

    const stepsSingleWrap = document.getElementById("story-steps-single");
    const stepsLegacyWrap = document.getElementById("story-steps-legacy");
    const singlePills = document.querySelectorAll("#story-steps-single .story-pill");
    const legacyPills = document.querySelectorAll("#story-steps-legacy .story-pill");

    // OpenUU Launcher elements (Step 0 & Step 1)
    const winOpenUU = document.getElementById("win-openuu");
    const winChat = document.getElementById("win-chat");
    const ouuConnectPane = document.getElementById("ouu-connect-pane");
    const ouuPickerPane = document.getElementById("ouu-picker-pane");
    const ouuCodeBox = document.getElementById("ouu-code-box");
    const ouuCodeText = document.getElementById("ouu-code-text");
    const ouuCodeCaret = document.getElementById("ouu-code-caret");
    const ouuPwdBox = document.getElementById("ouu-pwd-box");
    const ouuPwdText = document.getElementById("ouu-pwd-text");
    const ouuPwdCaret = document.getElementById("ouu-pwd-caret");
    const ouuConnectBtn = document.getElementById("ouu-connect-btn");
    const ouuConnectLabel = document.getElementById("ouu-connect-label");
    const ouuPullWxBtn = document.getElementById("ouu-pull-wx-btn");

    // Drag & WeChat & Notes elements (Step 2 & Step 3)
    const cursor = document.getElementById("demo-cursor");
    const notif = document.getElementById("mac-notif");
    const ghost = document.getElementById("drag-ghost");
    const finderPhotoRow = document.getElementById("finder-photo-row");
    const wxDropZone = document.getElementById("wx-drop-zone");
    const wxDropMask = document.getElementById("wx-drop-mask");
    const wxSentPhoto = document.getElementById("wx-sent-photo");
    const wxSentText = document.getElementById("wx-sent-text");
    const wxSidebarPreview = document.getElementById("wx-sidebar-preview");
    const todoChk = document.getElementById("todo-photo-chk");
    const todoLine = document.getElementById("todo-photo-line");
    const dockWxBtn = document.getElementById("dock-wx-btn");
    const dockUnread = document.getElementById("dock-unread-dot");

    // Legacy Pain elements
    const legacyTinyTarget = document.getElementById("legacy-tiny-target");
    const legacySecondDock = document.getElementById("legacy-second-dock");
    const legacyLocalNotes = document.getElementById("legacy-local-notes");
    const legacyToast = document.getElementById("legacy-pain-toast");

    if (!wallpaper || !cursor) return;

    let timers = [];
    let currentMode = "single";
    let lastStageKey = "";

    function updateStageScale() {
      if (!stageViewport || !wallpaper) return;
      const availW = stageViewport.clientWidth;
      const key = `${availW}:${currentMode}`;
      if (key === lastStageKey) return;
      lastStageKey = key;

      const designW = 960;
      if (availW > 0 && availW < designW) {
        const s = availW / designW;
        wallpaper.style.width = `${designW}px`;
        wallpaper.style.transform = `scale(${s})`;
        wallpaper.style.transformOrigin = "top left";
        stageViewport.style.height = `${Math.round(wallpaper.offsetHeight * s)}px`;
        stageViewport.style.aspectRatio = "auto";
      } else {
        wallpaper.style.width = "";
        wallpaper.style.transform = "";
        wallpaper.style.transformOrigin = "";
        stageViewport.style.height = "";
        stageViewport.style.aspectRatio = "";
      }
    }

    updateStageScale();
    if (stageViewport && typeof ResizeObserver !== "undefined") {
      new ResizeObserver(() => requestAnimationFrame(updateStageScale)).observe(stageViewport);
    } else {
      window.addEventListener("resize", updateStageScale);
    }

    function clearTimers() {
      timers.forEach((id) => clearTimeout(id));
      timers = [];
    }

    function after(ms, fn) {
      const id = setTimeout(fn, ms);
      timers.push(id);
    }

    function focusWin(key) {
      wins.forEach((w) => {
        const match = w.getAttribute("data-win") === key;
        w.classList.toggle("is-focused", match);
        if (match && activeApp) {
          activeApp.textContent = w.getAttribute("data-label") || "OpenUU";
        }
      });
      dockIcons.forEach((d) => {
        d.classList.toggle("active", d.getAttribute("data-win") === key);
      });
    }

    function getRelativePos(el, rx = 0.5, ry = 0.5) {
      if (!el) return { x: 440, y: 220 };
      const base = wallpaper.getBoundingClientRect();
      const r = el.getBoundingClientRect();
      if (r.width === 0 && r.height === 0) return { x: 440, y: 220 };
      const scale = base.width / (wallpaper.offsetWidth || base.width) || 1;
      return {
        x: Math.round((r.left - base.left + r.width * rx) / scale),
        y: Math.round((r.top - base.top + r.height * ry) / scale),
      };
    }

    function moveCursorTo(el, rx = 0.5, ry = 0.5) {
      const { x, y } = getRelativePos(el, rx, ry);
      cursor.style.transform = `translate3d(${x}px, ${y}px, 0)`;
      return { x, y };
    }

    function clickPulse() {
      cursor.classList.remove("clicking");
      void cursor.offsetWidth;
      cursor.classList.add("clicking");
    }

    function setSingleStep(idx) {
      singlePills.forEach((p, i) => p.classList.toggle("active", i === idx));
    }

    function setLegacyStep(idx) {
      legacyPills.forEach((p, i) => p.classList.toggle("active", i === idx));
    }

    function resetToStep0State() {
      if (notif) notif.classList.remove("visible");
      if (ghost) ghost.classList.remove("dragging");
      if (wxDropMask) wxDropMask.classList.remove("over");
      if (wxSentPhoto) wxSentPhoto.classList.remove("sent");
      if (wxSentText) wxSentText.classList.remove("sent");
      if (wxSidebarPreview) wxSidebarPreview.textContent = "老妈: 原图发群里";
      if (todoChk) todoChk.classList.remove("done");
      if (todoLine) todoLine.classList.remove("completed-line");
      if (legacyToast) legacyToast.classList.remove("show");

      // OpenUU Launcher starts visible; WeChat starts unopened
      if (winOpenUU) winOpenUU.classList.remove("win-minimized");
      if (winChat) winChat.classList.add("win-unopened");
      if (ouuConnectPane) ouuConnectPane.classList.remove("hidden-pane");
      if (ouuPickerPane) ouuPickerPane.classList.add("hidden-pane");

      if (ouuCodeBox) ouuCodeBox.classList.remove("typing-focus");
      if (ouuPwdBox) ouuPwdBox.classList.remove("typing-focus");
      if (ouuCodeText) ouuCodeText.innerHTML = '<span class="ouu-placeholder">例如 996 007 886</span>';
      if (ouuPwdText) ouuPwdText.innerHTML = '<span class="ouu-placeholder">输入访问密码</span>';
      if (ouuCodeCaret) ouuCodeCaret.style.display = "none";
      if (ouuPwdCaret) ouuPwdCaret.style.display = "none";
      if (ouuConnectBtn) ouuConnectBtn.classList.remove("pressed");
      if (ouuConnectLabel) ouuConnectLabel.textContent = "连接设备";

      if (connectedTag) connectedTag.textContent = "OpenUU 已连 1 台电脑";
      if (dockWxBtn) dockWxBtn.classList.add("dock-hidden");
      if (dockUnread) dockUnread.classList.add("cleared");
    }

    // Complete 4-Step Loop: OpenUU Connect -> Pick WeChat Window -> Drag Photo -> Check Todo
    function runSingleLoop() {
      clearTimers();
      if (currentMode !== "single") return;

      resetToStep0State();
      setSingleStep(0);
      focusWin("openuu");
      cursor.style.opacity = "1";

      // STEP 0: Type 9-digit code & password into OpenUU and click Connect
      after(250, () => {
        moveCursorTo(ouuCodeBox, 0.45, 0.5);
      });

      after(900, () => {
        clickPulse();
        if (ouuCodeBox) ouuCodeBox.classList.add("typing-focus");
        if (ouuCodeText) ouuCodeText.textContent = "";
        if (ouuCodeCaret) ouuCodeCaret.style.display = "inline-block";
      });

      after(1180, () => {
        if (ouuCodeText) ouuCodeText.textContent = "996";
      });
      after(1460, () => {
        if (ouuCodeText) ouuCodeText.textContent = "996 007";
      });
      after(1740, () => {
        if (ouuCodeText) ouuCodeText.textContent = "996 007 886";
      });

      after(2050, () => {
        moveCursorTo(ouuPwdBox, 0.42, 0.5);
      });

      after(2600, () => {
        clickPulse();
        if (ouuCodeBox) ouuCodeBox.classList.remove("typing-focus");
        if (ouuCodeCaret) ouuCodeCaret.style.display = "none";
        if (ouuPwdBox) ouuPwdBox.classList.add("typing-focus");
        if (ouuPwdText) ouuPwdText.textContent = "•••";
        if (ouuPwdCaret) ouuPwdCaret.style.display = "inline-block";
      });

      after(2950, () => {
        if (ouuPwdText) ouuPwdText.textContent = "••••••";
      });

      after(3250, () => {
        if (ouuPwdBox) ouuPwdBox.classList.remove("typing-focus");
        if (ouuPwdCaret) ouuPwdCaret.style.display = "none";
        moveCursorTo(ouuConnectBtn, 0.5, 0.5);
      });

      after(3900, () => {
        clickPulse();
        if (ouuConnectBtn) ouuConnectBtn.classList.add("pressed");
        if (ouuConnectLabel) ouuConnectLabel.textContent = "正在连接家里电脑…";
      });

      // STEP 1: Connected! Pick "微信" to pull out as an independent local window
      after(4450, () => {
        setSingleStep(1);
        if (connectedTag) connectedTag.textContent = "OpenUU 已连 2 台电脑";
        if (ouuConnectPane) ouuConnectPane.classList.add("hidden-pane");
        if (ouuPickerPane) ouuPickerPane.classList.remove("hidden-pane");
      });

      after(5050, () => {
        moveCursorTo(ouuPullWxBtn, 0.5, 0.5);
      });

      after(5900, () => {
        clickPulse();
        // OpenUU minimizes to Dock; Home Mac WeChat springs open natively + pops into Dock!
        if (winOpenUU) winOpenUU.classList.add("win-minimized");
        if (winChat) winChat.classList.remove("win-unopened");
        if (dockWxBtn) dockWxBtn.classList.remove("dock-hidden");
        focusWin("chat");
      });

      // STEP 2: Drag photo directly from Office Mac Finder into Home Mac WeChat
      after(6900, () => {
        setSingleStep(2);
        moveCursorTo(finderPhotoRow, 0.42, 0.55);
      });

      after(7750, () => {
        focusWin("files");
        clickPulse();
        const start = getRelativePos(finderPhotoRow, 0.25, 0.5);
        if (ghost) {
          ghost.style.transition = "none";
          ghost.style.setProperty("--ghost-pos", `translate3d(${start.x - 24}px, ${start.y - 14}px, 0)`);
          void ghost.offsetWidth;
          ghost.style.transition = "transform 0.9s cubic-bezier(0.25, 1, 0.35, 1), opacity 0.2s ease";
          ghost.classList.add("dragging");
        }
      });

      after(8050, () => {
        const dest = moveCursorTo(wxDropZone, 0.52, 0.48);
        if (ghost) {
          ghost.style.setProperty("--ghost-pos", `translate3d(${dest.x - 45}px, ${dest.y - 18}px, 0)`);
        }
        if (wxDropMask) wxDropMask.classList.add("over");
      });

      after(9050, () => {
        clickPulse();
        if (ghost) ghost.classList.remove("dragging");
        if (wxDropMask) wxDropMask.classList.remove("over");
        focusWin("chat");
        if (wxSentPhoto) wxSentPhoto.classList.add("sent");
        if (wxSidebarPreview) wxSidebarPreview.textContent = "我: [图片]";
      });

      after(9700, () => {
        if (wxSentText) wxSentText.classList.add("sent");
        if (wxSidebarPreview) wxSidebarPreview.textContent = "我: 刚直接拖进群里啦";
      });

      // STEP 3: Glide over to Local Notes and check off the todo item
      after(10650, () => {
        setSingleStep(3);
        moveCursorTo(todoChk, 0.5, 0.5);
      });

      after(11550, () => {
        clickPulse();
        focusWin("notes");
        if (todoChk) todoChk.classList.add("done");
        if (todoLine) todoLine.classList.add("completed-line");
      });

      after(13850, runSingleLoop);
    }

    // Choreographed Loop 2: Traditional Nested Remote Desktop Pain Points
    function showLegacyToast(text, targetEl, offsetY = -38) {
      if (!legacyToast || !targetEl) return;
      const pos = getRelativePos(targetEl, 0.5, 0.35);
      const clampedX = Math.max(24, Math.min(pos.x - 120, wallpaper.clientWidth - 300));
      const clampedY = Math.max(44, pos.y + offsetY);
      legacyToast.textContent = text;
      legacyToast.style.left = `${clampedX}px`;
      legacyToast.style.top = `${clampedY}px`;
      legacyToast.classList.add("show");
    }

    function runLegacyLoop() {
      clearTimers();
      if (currentMode !== "legacy") return;

      if (ghost) ghost.classList.remove("dragging");
      if (legacyToast) legacyToast.classList.remove("show");
      if (activeApp) activeApp.textContent = "传统远程桌面客户端";
      cursor.style.opacity = "1";

      setLegacyStep(0);
      after(200, () => {
        moveCursorTo(legacyTinyTarget, 0.28, 0.36);
      });
      after(1000, () => {
        clickPulse();
        showLegacyToast("整块 4K 大屏缩成 52%，小字发虚看不清", legacyTinyTarget, -18);
      });

      after(2800, () => {
        setLegacyStep(1);
        moveCursorTo(legacySecondDock, 0.5, 0.5);
      });
      after(3600, () => {
        clickPulse();
        showLegacyToast("上下两排程序坞叠在一起，极易误点", legacySecondDock, -46);
      });

      after(5400, () => {
        setLegacyStep(2);
        moveCursorTo(legacyLocalNotes, 0.35, 0.42);
      });
      after(6200, () => {
        clickPulse();
        showLegacyToast("大黑框挡住手头软件，也没法跨两台电脑拖文件", legacyLocalNotes, -16);
      });

      after(8200, runLegacyLoop);
    }

    function switchMode(mode) {
      currentMode = mode;
      segs.forEach((s) => s.classList.toggle("active", s.getAttribute("data-mode") === mode));
      wallpaper.setAttribute("data-mode", mode);
      if (stepsSingleWrap) stepsSingleWrap.style.display = mode === "single" ? "flex" : "none";
      if (stepsLegacyWrap) stepsLegacyWrap.style.display = mode === "legacy" ? "flex" : "none";
      updateStageScale();

      if (mode === "single") {
        runSingleLoop();
      } else {
        runLegacyLoop();
      }
    }

    // Clicking Dock icons or windows lets visitor explore interactively, then resumes
    dockIcons.forEach((d) => {
      d.addEventListener("click", () => {
        const key = d.getAttribute("data-win");
        if (!key) return;
        if (currentMode === "legacy") {
          switchMode("single");
          return;
        }
        clearTimers();
        if (key === "openuu") {
          if (winOpenUU) winOpenUU.classList.remove("win-minimized");
          if (winChat) winChat.classList.add("win-unopened");
        } else if (key === "chat") {
          if (winOpenUU) winOpenUU.classList.add("win-minimized");
          if (winChat) winChat.classList.remove("win-unopened");
        }
        focusWin(key);
        after(5000, () => {
          if (currentMode === "single") runSingleLoop();
        });
      });
    });

    segs.forEach((btn) => {
      btn.addEventListener("click", () => {
        const mode = btn.getAttribute("data-mode") || "single";
        switchMode(mode);
      });
    });

    if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      runSingleLoop();
    } else {
      cursor.style.display = "none";
      if (winOpenUU) winOpenUU.classList.add("win-minimized");
      if (winChat) winChat.classList.remove("win-unopened");
      if (dockWxBtn) dockWxBtn.classList.remove("dock-hidden");
      if (wxSentPhoto) wxSentPhoto.classList.add("sent");
      if (wxSentText) wxSentText.classList.add("sent");
    }
  }

  // 3. Auto-detect visitor OS for primary download button
  function detectOS() {
    const ua = navigator.userAgent || "";
    const platform = navigator.platform || "";
    const isIOS =
      /iPad|iPhone|iPod/i.test(ua) ||
      (platform === "MacIntel" && navigator.maxTouchPoints > 1);
    const isAndroid = /Android/i.test(ua);
    const isWindows = /Win/i.test(platform) || /Windows/i.test(ua);

    let os = "macos";
    if (isAndroid) os = "android";
    else if (isIOS) os = "ios";
    else if (isWindows) os = "windows";

    document.querySelectorAll(".dl-box[data-os]").forEach((box) => {
      const match = box.getAttribute("data-os") === os;
      box.classList.toggle("recommended", match);
      const tag = box.querySelector(".rec-tag");
      if (tag) tag.hidden = !match;
      const btn = box.querySelector("a.btn");
      if (btn) {
        btn.classList.toggle("btn-primary", match);
        btn.classList.toggle("btn-secondary", !match);
      }
    });

    const heroBtn = document.getElementById("hero-dl-btn");
    const heroLabel = document.getElementById("hero-dl-label");
    if (heroBtn && heroLabel) {
      const map = {
        macos: "免费下载 Mac 版",
        windows: "免费下载 Windows 版",
        android: "免费下载安卓版",
        ios: "下载 iPhone / iPad 版",
      };
      heroLabel.textContent = map[os] || map.macos;
      heroBtn.setAttribute("data-dl-role", os);
      const target = document.querySelector(`a[data-dl-link="${os}"]`);
      if (target) heroBtn.href = target.href;
    }

    const heroMoreLink = document.getElementById("hero-more-link");
    if (heroMoreLink) {
      heroMoreLink.textContent =
        os === "macos" || os === "windows" ? "查看全部平台与手机版 ›" : "查看 Mac / Windows 电脑版 ›";
    }
  }

  // 4. Keep download URLs & GitHub star badge synced
  async function syncRelease() {
    try {
      const repoResp = await fetch("https://api.github.com/repos/onekb/OpenUU", {
        headers: { Accept: "application/vnd.github+json" },
      });
      if (repoResp.ok) {
        const repo = await repoResp.json();
        const stars = Number(repo && repo.stargazers_count);
        if (Number.isFinite(stars) && stars > 0) {
          const formatted = stars >= 1000 ? `${(stars / 1000).toFixed(1)}k` : String(stars);
          document.querySelectorAll("[data-gh-stars]").forEach((el) => {
            el.textContent = `★ ${formatted}`;
            el.hidden = false;
          });
        }
      }
    } catch {
      // Optional star count badge
    }

    try {
      let resp = await fetch("/v1/latest-release").catch(() => null);
      if (!resp || !resp.ok) {
        resp = await fetch("https://api.github.com/repos/onekb/OpenUU/releases/latest", {
          headers: { Accept: "application/vnd.github+json" },
        });
      }
      if (!resp.ok) return;
      const rel = await resp.json();
      if (rel.tag_name) {
        document.querySelectorAll("[data-ver]").forEach((el) => {
          el.textContent = rel.tag_name;
        });
      }
      const fallbackReleaseUrl = rel.html_url || "https://github.com/onekb/OpenUU/releases/latest";
      const assets = Array.isArray(rel.assets) ? rel.assets : [];
      const map = {
        macos: assets.find((a) => /\.dmg$/i.test(a.name)),
        windows:
          assets.find((a) => /windows.*setup\.exe$/i.test(a.name)) ||
          assets.find((a) => /windows.*\.(exe|msi)$/i.test(a.name)) ||
          assets.find((a) => /windows.*\.zip$/i.test(a.name)),
        "windows-zip": assets.find((a) => /windows.*\.zip$/i.test(a.name)),
        android: assets.find((a) => /\.apk$/i.test(a.name)),
        ios: assets.find((a) => /\.ipa$/i.test(a.name)),
      };
      Object.entries(map).forEach(([k, asset]) => {
        const url = asset ? asset.browser_download_url : k === "windows" ? fallbackReleaseUrl : null;
        if (!url) return;
        document.querySelectorAll(`a[data-dl-link="${k}"]`).forEach((a) => {
          a.href = url;
        });
        const heroBtn = document.getElementById("hero-dl-btn");
        if (heroBtn && heroBtn.getAttribute("data-dl-role") === k) {
          heroBtn.href = url;
        }
      });
    } catch {
      // Fallback to v0.7.2 built-in URLs
    }
  }

  // 5. Simple Copy Helper
  function bindCopy(id, getText, normalLabel, copiedLabel) {
    const btn = document.getElementById(id);
    if (!btn) return;
    btn.addEventListener("click", async () => {
      const txt = getText();
      try {
        await navigator.clipboard.writeText(txt);
      } catch {
        const ta = document.createElement("textarea");
        ta.value = txt;
        ta.style.position = "fixed";
        ta.style.opacity = "0";
        document.body.appendChild(ta);
        ta.select();
        document.execCommand("copy");
        document.body.removeChild(ta);
      }
      btn.textContent = copiedLabel;
      setTimeout(() => {
        btn.textContent = normalLabel;
      }, 2000);
    });
  }

  document.addEventListener("DOMContentLoaded", () => {
    const promptEl = document.getElementById("ai-prompt-box");
    if (promptEl) promptEl.textContent = SELF_HOST_PROMPT;

    initDesktopStage();
    detectOS();
    checkHealth();
    syncRelease();

    bindCopy("copy-xattr", () => "xattr -cr /Applications/OpenUU.app", "复制命令", "已复制");
    bindCopy("copy-prompt", () => SELF_HOST_PROMPT, "复制一键部署提示词", "已复制");
  });
})();
