(() => {
  // Extracts the rows that are already rendered by the normal NetEase page.
  // It never calls an undocumented endpoint and never treats a virtualized
  // partial list as a complete playlist.
  const warnings = [];
  const embeddedFrame = document.querySelector("#g_iframe");
  let pageDocument = document;
  let pageLocation = location.href;
  if (embeddedFrame) {
    try {
      if (embeddedFrame.contentDocument && embeddedFrame.contentDocument !== document) {
        pageDocument = embeddedFrame.contentDocument;
        pageLocation = pageDocument.location.href || pageLocation;
      } else {
        warnings.push("网易云内容 iframe 尚未完成页面加载，当前结果不能视为完整歌单");
      }
    } catch (_) {
      warnings.push("无法读取同源网易云内容 iframe，当前结果不能视为完整歌单");
    }
  }
  const trim = (value) => String(value || "").replace(/\s+/g, " ").trim();
  const allowedHost = (host) => {
    const normalized = String(host || "").toLowerCase();
    return normalized === "music.163.com" || normalized.endsWith(".music.163.com");
  };
  const absoluteURL = (href) => {
    try {
      const url = new URL(href, pageLocation);
      if (url.protocol !== "http:" && url.protocol !== "https:") return null;
      if (!allowedHost(url.host)) return null;
      return url.href;
    } catch (_) { return null; }
  };
  const songIDFromURL = (href) => {
    const absolute = absoluteURL(href);
    if (!absolute) return null;
    try {
      const url = new URL(absolute);
      const route = `${url.pathname}${url.hash}`.toLowerCase();
      const isSongRoute = /(?:^|[#/])(?:song|track)(?:[/?#]|$)/.test(route);
      if (!isSongRoute) return null;
      const hashQuery = url.hash.includes("?") ? url.hash.split("?")[1] : "";
      const hashParams = new URLSearchParams(hashQuery);
      const fromQuery = url.searchParams.get("id") || url.searchParams.get("songId") || url.searchParams.get("songid")
        || hashParams.get("id") || hashParams.get("songId") || hashParams.get("songid");
      if (fromQuery && /^\d+$/.test(fromQuery)) return fromQuery;
      const match = `${url.pathname}${url.hash}`.match(/(?:song|track)[/_-](\d+)/i);
      return match ? match[1] : null;
    } catch (_) { return null; }
  };
  const playlistID = () => {
    try {
      const url = new URL(pageLocation);
      const route = `${url.pathname}${url.hash}`.toLowerCase();
      const isPlaylistRoute = /(?:^|[#/])(?:playlist|toplist)(?:[/?#]|$)/.test(route);
      if (!isPlaylistRoute) return null;
      const hashQuery = url.hash.includes("?") ? url.hash.split("?")[1] : "";
      const hashParams = new URLSearchParams(hashQuery);
      const fromQuery = url.searchParams.get("id") || url.searchParams.get("playlistId") || url.searchParams.get("playlistid")
        || hashParams.get("id") || hashParams.get("playlistId") || hashParams.get("playlistid");
      if (fromQuery && /^\d+$/.test(fromQuery)) return fromQuery;
      const match = `${url.pathname}${url.hash}`.match(/(?:playlist|toplist)(?:\/|%2F)(\d+)/i);
      return match ? match[1] : null;
    } catch (_) {
      const hashMatch = location.hash.match(/(?:playlist|toplist)[^\d]*(\d+)/i);
      return hashMatch ? hashMatch[1] : null;
    }
  };
  const firstText = (root, selectors) => {
    for (const selector of selectors) {
      const element = root.querySelector(selector);
      const value = trim(element && (element.getAttribute("content") || element.getAttribute("title") || element.textContent));
      if (value) return value;
    }
    return null;
  };
  const trackTitle = (row, link) => {
    const titleLink = row.querySelector("a[href*='/song?id='] b[title], a[href*='/song?id='][title], a[href*='/song/'] b[title]");
    const exactTitle = trim(titleLink && (titleLink.getAttribute("title") || titleLink.textContent));
    if (exactTitle) return exactTitle;
    const value = firstText(row, [
      ".ttc", ".txt", ".f-cb", ".m-table-song", ".song-name", "[data-field='name']", "[title]"
    ]);
    if (value) return value;
    return trim(link && (link.getAttribute("title") || link.textContent)) || null;
  };
  const trackArtists = (row) => {
    const value = firstText(row, [".text", ".by", ".s-fc3", ".artist", "[data-field='artists']"]);
    return value || null;
  };
  const rowSelectors = [
    ".m-table tbody tr",
    ".m-table-row",
    ".tracklist li",
    "[class*='track'][class*='item']"
  ];
  const songLinkIn = (root) => {
    const candidates = Array.from(root.querySelectorAll("a[href], [data-href], [data-url]"));
    return candidates.find((element) => {
      const href = element.getAttribute("href") || element.getAttribute("data-href") || element.getAttribute("data-url");
      return songIDFromURL(href) !== null;
    }) || null;
  };
  const songIDIn = (row, link) => {
    const linkHref = link && (link.getAttribute("href") || link.getAttribute("data-href") || link.getAttribute("data-url"));
    const fromLink = songIDFromURL(linkHref);
    if (fromLink) return fromLink;
    const attributes = ["data-song-id", "data-songid", "data-resid", "data-id", "song-id"];
    for (const name of attributes) {
      const value = row.getAttribute(name);
      if (value && /^\d+$/.test(value)) return value;
    }
    return null;
  };

  const rows = [];
  const seenRows = new Set();
  rowSelectors.forEach((selector) => {
    pageDocument.querySelectorAll(selector).forEach((row) => {
      // Normalize nested selector hits to the actual table/list row. This
      // avoids treating a play/favorite control with data-res-id as a song.
      const canonical = row.closest("tr") || row.closest(".m-table-row") || row.closest("li") || row;
      if (!seenRows.has(canonical)) {
        seenRows.add(canonical);
        rows.push(canonical);
      }
    });
  });
  rows.sort((left, right) => {
    if (left === right) return 0;
    const position = left.compareDocumentPosition(right);
    return position & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1;
  });

  const tracks = [];
  const seenFallbackIDs = new Set();
  const fallbackMode = rows.length === 0;
  const append = (row, link) => {
    const id = songIDIn(row, link);
    if (!id) return;
    const href = link && (link.getAttribute("href") || link.getAttribute("data-href") || link.getAttribute("data-url"));
    const url = absoluteURL(href) || `${location.origin}/song?id=${encodeURIComponent(id)}`;
    // Rows are the unit of ordering. When a page has no row containers, the
    // fallback below deduplicates repeated title/icon links for one song.
    if (fallbackMode && seenFallbackIDs.has(id)) return;
    if (fallbackMode) seenFallbackIDs.add(id);
    tracks.push({
      id,
      name: trackTitle(row, link),
      artists: trackArtists(row),
      order: tracks.length,
      url,
      sourceText: trim(row.textContent).slice(0, 500) || null
    });
  };

  rows.forEach((row) => append(row, songLinkIn(row)));
  if (tracks.length === 0) {
    const links = Array.from(pageDocument.querySelectorAll("a[href*='/song?id='], a[href*='/song/'], a[data-song-id]"));
    links.forEach((link) => append(link, link));
  }

  const bodyText = trim(pageDocument.body && pageDocument.body.innerText);
  const countCandidates = [];
  const countPatterns = [
    /(?:共|共有|total\s*[:：]?|songs?\s*[:：]?)\s*(\d+)\s*(?:首|首歌曲|songs?)?/i,
    /\((\d+)\s*(?:首|songs?)\)/i,
    /(\d+)\s*首歌曲/i
  ];
  countPatterns.forEach((pattern) => {
    const match = bodyText.match(pattern);
    if (match) countCandidates.push(Number(match[1]));
  });
  const totalCount = countCandidates.find((value) => Number.isSafeInteger(value) && value >= tracks.length) || null;

  const scrollingElement = pageDocument.scrollingElement || pageDocument.documentElement;
  const hasPagination = Boolean(pageDocument.querySelector(
    ".u-page, .m-pagination, [class*='pagination'], [aria-label*='下一页'], [aria-label*='next']"
  ));
  const likelyVirtualized = Boolean(scrollingElement && scrollingElement.scrollHeight > scrollingElement.clientHeight * 1.5 && tracks.length > 0 && !totalCount);
  let completeness = "notProven";
  let completenessReason = "页面未提供可核验的总曲目数，已读取行不能声明为完整歌单";
  if (totalCount !== null && totalCount === tracks.length && !hasPagination && !likelyVirtualized) {
    completeness = "complete";
    completenessReason = "公开 DOM 行数与页面公开总数一致";
  } else if (totalCount !== null && totalCount > tracks.length) {
    completeness = "partial";
    completenessReason = `页面公开总数为 ${totalCount}，当前 DOM 仅读取到 ${tracks.length} 行，可能仍有分页或虚拟列表未展开`;
  } else if (hasPagination || likelyVirtualized) {
    completeness = "partial";
    completenessReason = hasPagination ? "页面存在分页控件，当前 DOM 只是已读取页面" : "页面高度或渲染方式提示可能存在虚拟列表，未滚动读取全部行";
  }
  if (tracks.some((track) => !track.name)) warnings.push("部分曲目有 ID 和链接，但 DOM 没有暴露可核验的曲目名称");
  if (tracks.length === 0) warnings.push("当前页面 DOM 没有识别到带精确 ID 的歌曲行");
  if (tracks.some((track) => !track.url)) warnings.push("部分曲目没有可解析的链接");

  const title = firstText(pageDocument, [
    "meta[property='og:title']", ".g-crumb .f-cb", ".m-lycifo h2", ".u-cover + .cnt h2", "h1", "h2"
  ]) || document.title || null;
  return {
    sourceURL: pageLocation,
    playlistID: playlistID(),
    playlistName: title,
    extractedAt: new Date().toISOString(),
    tracks,
    totalCount,
    completeness,
    completenessReason,
    warnings
  };
})()
