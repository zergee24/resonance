((operation, payload) => {
  // This helper only dispatches the same DOM actions a signed-in user can
  // perform in the normal music.163.com page. It never sends a request, reads
  // cookies, or calls a platform endpoint directly.
  const trim = (value) => String(value || "").replace(/\s+/g, " ").trim();
  const frame = document.querySelector("#g_iframe");
  let pageDocument = document;
  if (frame && frame.contentDocument) pageDocument = frame.contentDocument;

  const visible = (element) => {
    if (!element) return false;
    const style = window.getComputedStyle(element);
    return style.display !== "none" && style.visibility !== "hidden" && style.opacity !== "0";
  };
  const visibleElement = (selector) => Array.from(pageDocument.querySelectorAll(selector)).find(visible) || null;
  const text = (element) => trim(element && element.textContent);
  const currentPlaylistModal = () => visibleElement(".m-favgd, .m-layer .m-favgd");
  const playlistItems = (root) => Array.from((root || pageDocument).querySelectorAll("li.xtag[data-id], li[data-id].xtag"))
    .map((item) => ({ id: item.getAttribute("data-id"), name: text(item.querySelector(".name")) || text(item) }))
    .filter((item) => item.id);
  const trackAddControl = (trackID) => {
    const value = String(trackID || "");
    return Array.from(pageDocument.querySelectorAll('[data-res-action="addto"][data-res-id]'))
      .find((element) => element.getAttribute("data-res-id") === value) || null;
  };
  const errorText = (root) => {
    const error = root && root.querySelector(".u-err:not(.f-vhide), .u-err:not(.f-hide), .f-error");
    return trim(error && error.textContent) || null;
  };

  if (operation === "readAccount") {
    const roots = [pageDocument, document];
    const selectors = [
      "[data-user-id]", "[data-uid]", "[data-account-id]",
      "a[href*='/user/home?id=']", "a[href*='/user?id=']",
      "a[href*='/user/']"
    ];
    for (const root of roots) {
      for (const selector of selectors) {
        const element = root.querySelector(selector);
        if (!element) continue;
        const attributeID = element.getAttribute("data-user-id") || element.getAttribute("data-uid") || element.getAttribute("data-account-id");
        let accountID = attributeID;
        if (!accountID) {
          try {
            const href = new URL(element.getAttribute("href"), location.href);
            accountID = href.searchParams.get("id");
          } catch (_) {}
        }
        if (accountID && /^\d+$/.test(accountID)) {
          return {
            ok: true,
            stage: "accountIdentified",
            accountID,
            accountName: element.getAttribute("title") || trim(element.textContent) || null,
            evidenceSelector: selector
          };
        }
      }
    }
    return { ok: false, stage: "accountUnknown", message: "正常页面 DOM 没有暴露可核验的当前账号 ID；为避免写入错误账号，已停止。" };
  }

  if (operation === "openAdd") {
    const control = trackAddControl(payload && payload.trackID);
    if (!control) {
      return { ok: false, stage: "trackNotRendered", message: "当前正常页面 DOM 没有该曲目的添加入口；可能仍在虚拟列表之外。" };
    }
    control.click();
    return { ok: true, stage: "addRequested" };
  }

  if (operation === "modalState") {
    const modal = currentPlaylistModal();
    return {
      ok: Boolean(modal),
      stage: modal ? "addModalVisible" : "addModalHidden",
      visible: Boolean(modal),
      message: modal ? null : "添加到歌单窗口尚未出现"
    };
  }

  if (operation === "createState") {
    const dialog = visibleElement(".m-crgd");
    return {
      ok: true,
      stage: dialog ? "createDialogVisible" : "createDialogHidden",
      visible: Boolean(dialog),
      message: dialog ? null : "新建歌单窗口已关闭"
    };
  }

  if (operation === "listPlaylists") {
    const modal = currentPlaylistModal();
    return {
      ok: Boolean(modal),
      stage: modal ? "playlistListVisible" : "addModalHidden",
      items: playlistItems(modal),
      message: modal ? null : "添加到歌单窗口尚未出现"
    };
  }

  if (operation === "createPlaylist") {
    const createDialog = visibleElement(".m-crgd");
    if (createDialog) {
      const input = createDialog.querySelector("input.u-txt, input[type='text']");
      const button = Array.from(createDialog.querySelectorAll(".u-btn2-2, a"))
        .find((element) => /新\s*建/.test(text(element)));
      if (!input || !button) {
        return { ok: false, stage: "createDialogUnavailable", message: "新建歌单窗口缺少名称输入框或新建按钮。" };
      }
      input.focus();
      input.value = String((payload && payload.name) || "");
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
      button.click();
      return { ok: true, stage: "createSubmitted" };
    }

    const modal = currentPlaylistModal();
    if (!modal) {
      return { ok: false, stage: "addModalHidden", message: "创建歌单前的添加到歌单窗口尚未出现。" };
    }
    const entry = Array.from(modal.querySelectorAll(".tit, [data-action]"))
      .find((element) => /新歌单/.test(text(element)));
    if (!entry) {
      return { ok: false, stage: "createEntryUnavailable", message: "当前添加到歌单窗口没有新歌单入口。" };
    }
    entry.click();
    return { ok: true, stage: "createDialogRequested" };
  }

  if (operation === "selectTarget") {
    const modal = currentPlaylistModal();
    if (!modal) return { ok: false, stage: "addModalHidden", message: "添加到歌单窗口已经关闭。" };
    const targetID = String((payload && payload.targetPlaylistID) || "");
    const target = Array.from(modal.querySelectorAll("li.xtag[data-id], li[data-id].xtag"))
      .find((element) => element.getAttribute("data-id") === targetID);
    if (!target) {
      return { ok: false, stage: "targetNotRendered", message: "目标歌单未出现在当前正常歌单选择窗口。" };
    }
    if (target.classList.contains("dis")) {
      return { ok: false, stage: "targetUnavailable", message: "目标歌单已满或当前账号不能添加。" };
    }
    target.click();
    return { ok: true, stage: "targetSelected" };
  }

  if (operation === "findCreatedPlaylist") {
    const wantedName = trim(payload && payload.name);
    const items = playlistItems(currentPlaylistModal());
    const matching = items.filter((item) => !wantedName || item.name === wantedName);
    return { ok: matching.length > 0, stage: "playlistListVisible", items: matching };
  }

  return { ok: false, stage: "unknownOperation", message: "未知的正常页面操作。" };
})
