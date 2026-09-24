((operation, payload) => {
  // This helper only dispatches actions already available in the normal
  // music.163.com page. It never calls a private endpoint, reads cookies, or
  // constructs a request outside the visible page UI.
  const trim = (value) => String(value || "").replace(/\s+/g, " ").trim();
  const frame = document.querySelector("#g_iframe");
  const pageDocument = frame && frame.contentDocument ? frame.contentDocument : document;
  const pageWindow = pageDocument.defaultView || window;

  const visible = (element) => {
    if (!element) return false;
    const style = (element.ownerDocument.defaultView || window).getComputedStyle(element);
    return style.display !== "none" && style.visibility !== "hidden" && style.opacity !== "0";
  };
  const visibleElement = (selector) => {
    const roots = pageDocument === document ? [document] : [pageDocument, document];
    for (const root of roots) {
      const element = Array.from(root.querySelectorAll(selector)).find(visible);
      if (element) return element;
    }
    return null;
  };
  const text = (element) => trim(element && element.textContent);
  const currentPlaylistModal = () => visibleElement(".m-favgd, .m-layer .m-favgd");
  const playlistItems = (root) => Array.from((root || pageDocument).querySelectorAll("li.xtag[data-id], li[data-id].xtag"))
    .map((item) => ({ id: item.getAttribute("data-id"), name: text(item.querySelector(".name")) || text(item) }))
    .filter((item) => item.id);
  const trackAddControl = (trackID) => {
    const value = String(trackID || "");
    const roots = pageDocument === document ? [document] : [pageDocument, document];
    for (const root of roots) {
      const control = Array.from(root.querySelectorAll('[data-res-action="addto"][data-res-id]'))
        .find((element) => element.getAttribute("data-res-id") === value && visible(element));
      if (control) return control;
    }
    return null;
  };
  const headerRoot = () => document.querySelector("#g-top, #g-top-box, .m-top, header");
  const headerVisible = (selector) => {
    const root = headerRoot();
    return root ? Array.from(root.querySelectorAll(selector)).find(visible) || null : null;
  };

  if (operation === "headerState") {
    // Identity is read only from the site's top header. No user ID is
    // returned, so links in song/playlist content can never identify an
    // account for this write.
    const loggedInMarker = headerVisible(
      ".m-logged, .m-top-3 .user, .m-tophead .m-tlist a[href*='/user/'], " +
      "a[href*='/user/home?id='], a[href*='/user?id='], [data-user-id], [data-uid]"
    );
    const loginControl = headerVisible(".login, .m-top-3 .login, a[href*='/login']");
    if (loggedInMarker && !loginControl) {
      return { ok: true, loggedIn: true, stage: "headerLoggedIn" };
    }
    if (loginControl) {
      return { ok: false, loggedIn: false, stage: "headerLoggedOut", message: "请先在网易云页面顶部完成登录。" };
    }
    return { ok: false, loggedIn: false, stage: "headerIdentityUnknown", message: "无法从网易云站点顶部确认登录状态，请先打开页面并完成登录。" };
  }

  if (operation === "openAdd") {
    const control = trackAddControl(payload && payload.trackID);
    if (!control) {
      return { ok: false, stage: "trackNotRendered", message: "当前正常页面 DOM 没有该曲目的添加入口；页面可能仍在虚拟加载。" };
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

  if (operation === "requestCreate") {
    const dialog = visibleElement(".m-crgd");
    if (dialog) return { ok: true, stage: "createDialogVisible" };
    const modal = currentPlaylistModal();
    if (!modal) return { ok: false, stage: "addModalHidden", message: "创建歌单前的添加窗口尚未出现。" };
    const entry = Array.from(modal.querySelectorAll(".tit, [data-action], a, button"))
      .find((element) => /新\s*歌单/.test(text(element)) && visible(element));
    if (!entry) return { ok: false, stage: "createEntryUnavailable", message: "当前添加窗口没有新歌单入口。" };
    entry.click();
    return { ok: true, stage: "createDialogRequested" };
  }

  if (operation === "submitCreate") {
    const dialog = visibleElement(".m-crgd");
    if (!dialog) return { ok: false, stage: "createNotSubmitted", message: "新建歌单窗口尚未出现。" };
    const input = dialog.querySelector("input.u-txt, input[type='text']");
    const button = Array.from(dialog.querySelectorAll(".u-btn2-2, a, button"))
      .find((element) => /新\s*建/.test(text(element)) && visible(element));
    const name = trim(payload && payload.name);
    if (!input || !button || !name) {
      return { ok: false, stage: "createNotSubmitted", message: "新建歌单窗口缺少名称输入框或新建按钮。" };
    }
    input.focus();
    input.value = name;
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.dispatchEvent(new Event("change", { bubbles: true }));
    button.click();
    return { ok: true, stage: "createSubmitted" };
  }

  if (operation === "selectTarget") {
    const modal = currentPlaylistModal();
    if (!modal) return { ok: false, stage: "addModalHidden", message: "添加到歌单窗口已经关闭。" };
    const targetID = String((payload && payload.targetPlaylistID) || "");
    const target = Array.from(modal.querySelectorAll("li.xtag[data-id], li[data-id].xtag"))
      .find((element) => element.getAttribute("data-id") === targetID && visible(element));
    if (!target) return { ok: false, stage: "targetNotRendered", message: "目标歌单未出现在当前正常歌单选择窗口。" };
    if (target.classList.contains("dis")) return { ok: false, stage: "targetUnavailable", message: "目标歌单当前不可添加。" };
    target.click();
    return { ok: true, stage: "targetSelected" };
  }

  return { ok: false, stage: "unknownOperation", message: "未知的正常页面操作。" };
})
