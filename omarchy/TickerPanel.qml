pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Market table popup + data owner. This panel runs `tickerbar --output json`
// (the structured raw-data mode) on a timer and exposes the parsed snapshot;
// BarWidget.qml renders the compact bar strip from `barEntries`.
Panel {
  id: root
  moduleName: "mryll.tickerbar"
  ipcTarget: "mryll.tickerbar"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar identifies this panel by the widget mounted in its slot, not by
  // this nested item — same contract as the first-party weather plugin.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Last successfully parsed `tickerbar --output json` document. Kept on
  // fetch/parse failure so stale data stays visible instead of flashing empty.
  property var snapshot: null

  // Run-level failure (binary missing, malformed output). Cleared by the next
  // good document; last-known-good data stays rendered under the error banner.
  property string runError: ""

  // The panel draws on the POPUP CARD, so it takes the popup surface's text
  // token — not the bar's. bar.foreground is chosen against the bar, which on a
  // transparent bar means "against the wallpaper"; that is the wrong contrast
  // reference for a card, and a theme that defines popups.text separately would
  // be ignored outright. (printbar already did this; the rest of the family now
  // agrees.)
  readonly property color panelFg: Commons.Color.popups.text
  readonly property color mutedFg: Qt.darker(panelFg, 1.55)

  // ---- Freshness suffix tint, shared by the whole family. The timestamp is
  // ALWAYS dim ("when is this from" is information, not a warning); only the
  // "· stale" / "· partial data" suffix carries a muted warning tone.
  readonly property color freshnessWarn: panelColored
    ? mixColor(mutedFg, urgentColor, 0.4) : mutedFg
  readonly property color urgentColor: root.bar ? root.bar.urgent : Commons.Color.urgent
  readonly property string panelFont: root.bar ? root.bar.fontFamily : Style.font.family

  readonly property int refreshSeconds: Math.max(5, parseInt(setting("refreshIntervalSec", 60), 10) || 60)

  // Tri-state summary: "follow" honors the TOML's summary_format presence,
  // "show"/"hide" force it either way. It governs the BAR STRIP only — see
  // summaryChipVisible for the panel, which shows the average by default.
  readonly property string summaryMode: String(setting("summaryMode", "follow"))
  readonly property bool showSummary: summaryMode === "show"
    || (summaryMode !== "hide" && snapshot !== null && snapshot.summary_configured === true)

  // Monochrome, mirroring the CLI's `--no-color`: "full" (default), "none",
  // "bar-only" (colored bar face, monochrome panel) and "panel-only" (the
  // reverse). Dimming and the muted closed/stale treatments are NOT color, so
  // they survive every mode; only accent/urgent tinting is gated.
  // An unrecognized value normalizes to "full": a hand-edited shell.json must
  // not be able to silently take the color off both surfaces.
  readonly property string colorMode: {
    var v = String(setting("colorMode", "full"))
    return ["full", "none", "bar-only", "panel-only"].indexOf(v) >= 0 ? v : "full"
  }
  readonly property bool barColored:   colorMode === "full" || colorMode === "bar-only"
  readonly property bool panelColored: colorMode === "full" || colorMode === "panel-only"

  readonly property string binName: "tickerbar"
  readonly property string configPath: String(setting("configPath", "")).trim()

  // Measurements sent with the last run, to detect when fresh content moves
  // the fit and one cache-hot repack run is warranted.
  property int lastSentBudget: 0
  property int lastSentMaxCols: 0

  function buildCmd() {
    var args = [binName, "--output", "json"]
    if (configPath !== "") { args.push("--config"); args.push(configPath) }
    // Presentation measurements only — the CORE merges them with the config
    // (an explicit tooltip_rows_per_column > 0 wins; max-columns takes the
    // smaller positive value) and does ALL the packing.
    lastSentBudget = autoLineBudget
    lastSentMaxCols = maxFitColumns
    args.push("--rows-per-column"); args.push(String(lastSentBudget))
    args.push("--max-columns"); args.push(String(lastSentMaxCols))
    return args
  }

  // A settings change mid-poll must not be dropped: startRun queues the new
  // command (last-command-wins) while a run is in flight.
  onConfigPathChanged: startRun(buildCmd())

  readonly property var groups: snapshot && snapshot.groups ? snapshot.groups : []

  // ---- Detail card state. Clicking a table row opens that asset. The KEY
  //      (label|symbol) is stored, not the row object, so the card follows
  //      every refresh in place — and closes itself when the asset leaves the
  //      watchlist.
  property string selectedKey: ""

  function rowKey(r) {
    if (!r) return ""
    var sym = (r.symbol === undefined || r.symbol === null) ? "" : String(r.symbol)
    return String(r.label) + "\u001f" + sym
  }

  function findSelectedRow() {
    if (selectedKey === "") return null
    for (var i = 0; i < groups.length; i++) {
      var rows = groups[i].rows || []
      for (var j = 0; j < rows.length; j++)
        if (root.rowKey(rows[j]) === root.selectedKey) return rows[j]
    }
    return null
  }

  function findSelectedGroup() {
    if (selectedKey === "") return null
    for (var i = 0; i < groups.length; i++) {
      var rows = groups[i].rows || []
      for (var j = 0; j < rows.length; j++)
        if (root.rowKey(rows[j]) === root.selectedKey) return groups[i]
    }
    return null
  }

  readonly property var selectedRow: findSelectedRow()
  readonly property var selectedGroup: findSelectedGroup()

  function showDetail(r) {
    root.selectedKey = root.rowKey(r)
  }

  function clearDetail() {
    root.selectedKey = ""
  }

  // Copy-the-symbol affordance (same two-state check the install button uses).
  property bool symbolCopied: false
  Timer {
    id: symbolCopiedReset
    interval: 1500
    onTriggered: root.symbolCopied = false
  }

  // ---- Detail card values. Everything is derived from the row the table
  //      already holds, so opening the card costs no extra request.
  readonly property string detailSymbol: selectedRow
    ? ((selectedRow.symbol === undefined || selectedRow.symbol === null) ? "" : String(selectedRow.symbol)) : ""
  readonly property string detailGlyph: selectedRow ? String(selectedRow.glyph || "") : ""
  readonly property string detailSource: (selectedGroup && selectedGroup.sources)
    ? selectedGroup.sources.join("·") : ""
  readonly property string detailPriceText: selectedRow ? priceText(selectedRow) : ""
  readonly property string detailCurrency: (selectedRow && selectedRow.unit === "currency" && selectedRow.quote)
    ? " " + String(selectedRow.quote).toUpperCase() : ""
  readonly property string detailChangeText: {
    var r = root.selectedRow
    if (!r) return ""
    var t = chgCellText(r)
    return t !== "" ? t : "—"
  }
  readonly property color detailDirColor: root.panelDirColor(selectedRow ? selectedRow.direction : null)
  readonly property real detailRangePos: selectedRow ? rangePosition(selectedRow) : -1
  readonly property string detailMeta: {
    var r = root.selectedRow
    if (!r) return ""
    var parts = []
    if (detailSymbol !== "") parts.push(detailSymbol)
    if (detailSource !== "") parts.push(detailSource)
    var m = marketLabel(r)
    if (m !== "") parts.push(m)
    var s = stateLabel(r)
    if (s !== "") parts.push(s)
    return parts.join(" · ")
  }

  // A failed plugin run counts as stale even when the cached snapshot still
  // says "ok" — the prices on screen are the last good ones either way.
  readonly property string lifecycle: pluginStale
    ? "stale" : (snapshot ? String(snapshot.state || "") : "")
  readonly property string topError: runError !== "" ? runError
    : (snapshot && snapshot.error && snapshot.error.message ? String(snapshot.error.message) : "")

  readonly property string updatedText: {
    if (!snapshot || !snapshot.fetched_at) return ""
    var d = new Date(snapshot.fetched_at)
    return isNaN(d.getTime()) ? "" : Qt.formatTime(d, "HH:mm")
  }

  // ---- Formatting (mirrors the Rust renderer: grouped thousands, 2/4 decimals,
  //      rates as percents). Numbers arrive raw; all presentation happens here.
  function fmtNumber(v) {
    var a = Math.abs(v)
    if (a >= 1000) return Number(v).toLocaleString(Qt.locale("en_US"), 'f', 2)
    if (a >= 1) return Number(v).toFixed(2)
    return Number(v).toFixed(4)
  }

  function priceText(r) {
    if (r.price === null || r.price === undefined) return "—"
    if (r.unit === "percent") return Number(r.price).toFixed(2) + "%"
    return fmtNumber(r.price)
  }

  // Mirrors the CLI's fmt_change: signed, EXCEPT a flat quote, which renders
  // unsigned with a leading space so the right-aligned column keeps its width.
  // Flatness comes from the document's `direction`, not from the rounded number,
  // so a tiny-but-nonzero move that prints as 0.00 keeps its real sign.
  function changeText(c, dir) {
    if (c === null || c === undefined) return ""
    if (dir === "flat") return " " + Math.abs(Number(c)).toFixed(2) + "%"
    return (c >= 0 ? "+" : "") + Number(c).toFixed(2) + "%"
  }

  // Direction is already double-encoded (sign + tint); a triangle on top of
  // that was redundant, so the change cell is just the signed percent.
  function chgCellText(r) {
    return changeText(r.change_pct, r.direction)
  }

  function rangeText(r) {
    if (r.day_low === null || r.day_low === undefined) return ""
    if (r.day_high === null || r.day_high === undefined) return ""
    if (r.unit === "percent")
      return Number(r.day_low).toFixed(2) + "%–" + Number(r.day_high).toFixed(2) + "%"
    return fmtNumber(r.day_low) + "–" + fmtNumber(r.day_high)
  }

  // ---- Detail-card derivations. The payload carries the price, the day's
  //      percent move and the day's low/high — nothing else — so the previous
  //      close and the absolute change are IMPLIED from the percent instead of
  //      being fetched from a second source and printed as if it were fact.
  function prevClose(r) {
    if (!r || r.price === null || r.price === undefined) return null
    if (r.change_pct === null || r.change_pct === undefined) return null
    var pct = Number(r.change_pct)
    if (!isFinite(pct) || pct <= -100) return null
    return Number(r.price) / (1 + pct / 100)
  }

  function prevText(r) {
    var prev = prevClose(r)
    if (prev === null) return ""
    if (r.unit === "percent") return prev.toFixed(2) + "%"
    return fmtNumber(prev) + root.detailCurrency
  }

  function amountText(r) {
    var prev = prevClose(r)
    if (prev === null) return "—"
    var d = Number(r.price) - prev
    var sign = d > 0 ? "+" : (d < 0 ? "−" : " ")
    var body = r.unit === "percent" ? Math.abs(d).toFixed(2) + "pp" : fmtNumber(Math.abs(d))
    return sign + body
  }

  // (high - low) over the previous close: the session's amplitude.
  function amplitudeText(r) {
    var prev = prevClose(r)
    if (prev === null || prev === 0) return ""
    if (r.day_low === null || r.day_low === undefined) return ""
    if (r.day_high === null || r.day_high === undefined) return ""
    return Math.abs((Number(r.day_high) - Number(r.day_low)) / prev * 100).toFixed(2) + "%"
  }

  // Where the price sits inside the day's range: 0 = at the low, 1 = at the
  // high, -1 = no usable range (no session data yet).
  function rangePosition(r) {
    if (!r) return -1
    if (r.day_low === null || r.day_low === undefined) return -1
    if (r.day_high === null || r.day_high === undefined) return -1
    var lo = Number(r.day_low)
    var hi = Number(r.day_high)
    if (!(hi > lo)) return -1
    var p = (Number(r.price) - lo) / (hi - lo)
    if (!isFinite(p)) return -1
    return Math.max(0, Math.min(1, p))
  }

  function marketLabel(r) {
    if (!r) return ""
    if (r.market === "closed") return "closed"
    if (r.market === "open") return "open"
    return ""
  }

  function stateLabel(r) {
    if (!r) return ""
    var s = (r.state === undefined || r.state === null) ? "" : String(r.state)
    if (s === "stale") return "stale (cached)"
    if (s === "missing") return "no data"
    return s
  }

  // ---- Fundamentals from the detail feed. Absent fields drop their row
  //      instead of printing a dash, so an index shows the session facts it
  //      has and nothing that pretends a cap exists.
  function quoteValue(key, digits) {
    var q = root.detailQuote
    if (!q) return ""
    var v = q[key]
    if (v === null || v === undefined || v === "") return ""
    var n = Number(v)
    if (!isFinite(n)) return ""
    return digits === undefined ? String(v) : n.toFixed(digits)
  }

  readonly property string detailRangeText: {
    var q = root.detailQuote
    if (!q || q.yrLow === null || q.yrLow === undefined || q.yrHigh === null || q.yrHigh === undefined)
      return ""
    return fmtNumber(q.yrLow) + "–" + fmtNumber(q.yrHigh)
  }

  readonly property string detailMarketCapText: {
    var q = root.detailQuote
    if (!q || !q.marketCap) return ""
    return (q.currency ? String(q.currency) + " " : "") + String(q.marketCap)
  }

  // The card's key/value block, in reading order: what it costs, what moved,
  // where the move started, how wide the day was, then the provenance. The
  // right column carries fundamentals and only exists when the feed returned
  // any, so an index does not print a column of dashes.
  readonly property var detailRows: {
    var r = root.selectedRow
    if (!r) return []
    var rows = []
    var chg = root.detailChangeText
    rows.push({ label: "Price", value: root.detailPriceText + root.detailCurrency, dir: null, strong: true })
    rows.push({ label: "Day change", value: root.amountText(r) + (chg !== "—" ? "  (" + chg + ")" : ""), dir: r.direction, strong: false })
    var prev = root.prevText(r)
    rows.push({ label: "Prev close", value: prev !== "" ? prev : "—", dir: null, strong: false })
    var open = root.quoteValue("open")
    if (open !== "") rows.push({ label: "Open", value: fmtNumber(Number(open)) + root.detailCurrency, dir: null, strong: false })
    var range = root.rangeText(r)
    rows.push({ label: "Day range", value: range !== "" ? range + root.detailCurrency : "—", dir: null, strong: false })
    if (root.detailRangeText !== "") rows.push({ label: "52w range", value: root.detailRangeText, dir: null, strong: false })
    var amp = root.amplitudeText(r)
    rows.push({ label: "Amplitude", value: amp !== "" ? amp : "—", dir: null, strong: false })
    var market = root.marketLabel(r)
    rows.push({ label: "Market", value: market !== "" ? market : "—", dir: null, strong: false })
    rows.push({ label: "Data", value: root.stateLabel(r) + (root.detailSource !== "" ? " · " + root.detailSource : ""), dir: null, strong: false })
    return rows
  }

  readonly property var detailRowsRight: {
    var q = root.detailQuote
    if (!q) return []
    var rows = []
    var pe = root.quoteValue("pe", 2)
    if (pe !== "") rows.push({ label: "P/E", value: pe, dir: null, strong: false })
    var eps = root.quoteValue("eps", 2)
    if (eps !== "") rows.push({ label: "EPS", value: eps, dir: null, strong: false })
    if (q.volume !== null && q.volume !== undefined)
      rows.push({ label: "Volume", value: root.compactNumber(q.volume), dir: null, strong: false })
    if (q.avgVolume) rows.push({ label: "10d avg vol", value: String(q.avgVolume), dir: null, strong: false })
    var beta = root.quoteValue("beta", 2)
    if (beta !== "") rows.push({ label: "Beta", value: beta, dir: null, strong: false })
    if (q.divYield) rows.push({ label: "Div yield", value: String(q.divYield), dir: null, strong: false })
    if (q.sharesOut) rows.push({ label: "Shares out", value: String(q.sharesOut), dir: null, strong: false })
    if (q.exchange) rows.push({ label: "Exchange", value: String(q.exchange), dir: null, strong: false })
    if (q.name) rows.push({ label: "Name", value: String(q.name), dir: null, strong: false })
    return rows
  }

  // The quote page: CNBC (which backs stocks, indices, commodities and rates)
  // takes the exact symbol the payload carries, so `.SSEC` or `6702-JP` land
  // on the right page. Anything else falls back to a web search for the label,
  // so the button is never a dead end.
  function quoteUrl() {
    var r = root.selectedRow
    if (!r) return ""
    if (root.detailSymbol !== "" && root.detailSource.indexOf("cnbc") >= 0)
      return "https://www.cnbc.com/quotes/" + encodeURIComponent(root.detailSymbol)
    return "https://www.google.com/search?q="
      + encodeURIComponent(String(r.label) + " " + root.detailSymbol)
  }

  function openQuote() {
    var url = root.quoteUrl()
    if (url !== "") Util.execArgv(["omarchy-launch-browser", url])
  }

  function copySymbol() {
    if (root.detailSymbol === "") return
    Util.execArgv(["wl-copy", root.detailSymbol])
    root.symbolCopied = true
    symbolCopiedReset.restart()
  }

  // ---- Detail feed: market cap, P/E, 52-week range and OHLC candles. The
  //      panel's own JSON carries none of that, so a companion script runs
  //      for the SELECTED symbol only — same CNBC provider and the same symbol
  //      vocabulary as the prices above, two requests per run. All of it is
  //      optional: when the feed fails the card still shows what the table
  //      already had, plus one quiet line saying why.
  property var detailFeed: null
  property string detailRange: "1D"      // 1D | 1W | 1Y
  property string detailFeedError: ""
  property bool detailFeedBusy: false
  property string detailFeedSymbol: ""   // the symbol detailFeed belongs to
  property double detailFeedAt: 0
  property var detailCache: ({})         // symbol -> { doc, at }
  property string detailRequestSymbol: ""
  property bool detailRequestQueued: false
  property bool detailCollectorDone: true
  property bool detailProcessDone: true
  property string detailCaptured: ""
  property int detailExitCode: 0

  readonly property string detailScript: {
    var override = String(setting("detailScript", "")).trim()
    if (override !== "") return override
    var base = Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
    return base + "/omarchy/plugins/mryll.tickerbar/scripts/quote_detail.py"
  }

  // Only CNBC-backed rows share the feed's symbol vocabulary. A row from
  // another provider (a CoinGecko id, an ARS house) would get a chart of some
  // OTHER instrument with the same letters, so it gets no feed at all.
  readonly property bool detailFeedSupported: detailSource.indexOf("cnbc") >= 0

  readonly property var detailQuote: (detailFeed && detailFeed.quote
    && detailFeedSymbol === detailSymbol) ? detailFeed.quote : null

  readonly property var detailCandles: {
    if (!detailFeed || !detailFeed.ranges || detailFeedSymbol !== detailSymbol) return []
    var range = detailFeed.ranges[root.detailRange]
    return (range && range.candles) ? range.candles : []
  }

  // Min/max of the visible series, shared by the canvas and the two scale
  // labels so they cannot disagree.
  readonly property var detailBounds: {
    var data = detailCandles
    var hi = -Infinity
    var lo = Infinity
    for (var i = 0; i < data.length; i++) {
      if (Number(data[i].h) > hi) hi = Number(data[i].h)
      if (Number(data[i].l) < lo) lo = Number(data[i].l)
    }
    return { hi: hi, lo: lo }
  }

  readonly property bool detailLoadingHere: detailFeedBusy && detailRequestSymbol === detailSymbol

  readonly property string detailChartStatus: {
    if (detailLoadingHere) return "Loading…"
    if (detailFeedError !== "") return detailFeedError
    if (detailFeed && detailCandles.length === 0) return "no candles for this range"
    return ""
  }

  function compactNumber(v) {
    if (v === null || v === undefined) return "—"
    var n = Number(v)
    if (!isFinite(n)) return "—"
    var a = Math.abs(n)
    if (a >= 1e12) return (n / 1e12).toFixed(2) + "T"
    if (a >= 1e9) return (n / 1e9).toFixed(2) + "B"
    if (a >= 1e6) return (n / 1e6).toFixed(2) + "M"
    if (a >= 1e3) return (n / 1e3).toFixed(1) + "K"
    return String(Math.round(n))
  }

  function requestDetail(force) {
    var sym = root.detailSymbol
    if (sym === "") return
    if (!root.detailFeedSupported) return
    var cached = root.detailCache[sym]
    var now = Date.now()
    if (!force && cached && (now - cached.at) < 55000) {
      root.applyDetail(sym, cached.doc, cached.at)
      return
    }
    if (root.detailFeedBusy) { root.detailRequestQueued = true; return }
    root.startDetailRun(sym)
  }

  function startDetailRun(sym) {
    root.detailRequestSymbol = sym
    root.detailFeedBusy = true
    root.detailCollectorDone = false
    root.detailProcessDone = false
    root.detailCaptured = ""
    root.detailExitCode = 0
    // Through sh, never direct: a missing script must not abort the shell
    // inside a failed process start (see startRun above).
    detailProc.command = ["/bin/sh", "-c", 'exec timeout 25 "$0" "$@"', root.detailScript, "--symbol", sym]
    detailProc.running = true
  }

  function applyDetail(sym, doc, at) {
    if (root.detailSymbol !== sym) return
    root.detailFeed = doc
    root.detailFeedSymbol = sym
    root.detailFeedAt = at
    root.detailFeedError = (doc && doc.error) ? String(doc.error) : ""
  }

  function maybeApplyDetail() {
    if (!root.detailCollectorDone || !root.detailProcessDone) return
    root.detailFeedBusy = false
    var sym = root.detailRequestSymbol
    var doc = null
    try { doc = JSON.parse(root.detailCaptured) } catch (e) { doc = null }
    if (doc && doc.schema === 1) {
      var now = Date.now()
      root.detailCache[sym] = { doc: doc, at: now }
      root.applyDetail(sym, doc, now)
    } else if (root.detailSymbol === sym) {
      root.detailFeed = null
      root.detailFeedSymbol = sym
      root.detailFeedError = (root.detailExitCode === 124)
        ? "detail feed timed out"
        : (root.detailExitCode === 126 || root.detailExitCode === 127)
        ? "detail script not found"
        : (root.detailCaptured.trim() === "" ? "detail feed produced no output"
                                            : "detail feed returned unreadable data")
    }
    if (root.detailRequestQueued) {
      root.detailRequestQueued = false
      Qt.callLater(function() { root.requestDetail(true) })
    }
  }

  // Pointing at a row starts its feed early. The request is slow (one round
  // trip through whatever proxy this machine sits behind) and the cache is
  // shared, so this is the difference between "click and wait" and "click and
  // read". Nothing is queued: a busy prefetch is simply skipped, and a run
  // that lands for a row the user did not pick only fills the cache.
  property string hoverSymbol: ""
  Timer {
    id: hoverPrefetch
    interval: 280
    repeat: false
    onTriggered: root.prefetchDetail(root.hoverSymbol)
  }

  function noteHover(r) {
    var sym = (r && r.symbol !== undefined && r.symbol !== null) ? String(r.symbol) : ""
    if (sym === "" || sym === root.detailSymbol) return
    if (root.detailCache[sym] || root.detailFeedBusy) return
    root.hoverSymbol = sym
    hoverPrefetch.restart()
  }

  function prefetchDetail(sym) {
    if (sym === "" || sym === root.detailSymbol) return
    if (!root.detailFeedSupported) return
    if (root.detailCache[sym] || root.detailFeedBusy) return
    root.startDetailRun(sym)
  }

  // A new asset loads its card; the panel's own refresh keeps it current.
  onSelectedKeyChanged: {
    if (selectedKey === "") {
      detailFeed = null
      detailFeedSymbol = ""
      detailFeedError = ""
      return
    }
    if (!detailFeedSupported) {
      detailFeed = null
      detailFeedSymbol = detailSymbol
      detailFeedError = "no chart for this data source"
      return
    }
    requestDetail(false)
  }

  onSnapshotChanged: {
    if (selectedKey !== "") requestDetail(false)
  }

  // `groupClosed` suppresses the per-row closed marker when the whole section
  // is closed — the header already says it once; repeating it on sixty rows
  // is noise, not information.
  function noteText(r, groupClosed) {
    var parts = []
    var range = rangeText(r)
    if (range !== "") parts.push(range)
    if (r.market === "closed" && groupClosed !== true) parts.push(" closed")
    if (r.state === "stale") parts.push("stale")
    else if (r.state === "error")
      parts.push(r.error && r.error.message ? String(r.error.message) : "n/d")
    else if (r.state === "missing" && groupClosed !== true)
      // Missing data in a fully-closed section is expected (no session cache
      // yet) — the header's pause marker already explains it; per-row "no
      // data" only matters while the market is open.
      parts.push(r.error && r.error.message ? String(r.error.message) : "n/d")
    return parts.join("  ")
  }

  // ---- Direction tinting: interpolate from the theme foreground toward the
  //      theme accent (up) / urgent (down), so every Omarchy theme works.
  //      No hardcoded green/red.
  function mixColor(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
  }

  // ---- The CORE publishes the direction colours it paints with (`palette.up` /
  //      `.down` / `.flat`, the same values its Waybar renderer uses), so the panel,
  //      the bar strip and the Waybar tooltip agree on what a given number looks
  //      like. Re-deriving them here from the accent is what made `+2.14%` render
  //      accent-blue in the panel and theme-green everywhere else.
  readonly property var palette: snapshot && snapshot.palette ? snapshot.palette : null

  function paletteColor(key, fallback) {
    if (!palette) return fallback
    var v = palette[key]
    return (typeof v === "string" && v.charAt(0) === "#") ? v : fallback
  }

  // Where a direction wants to land. Documents from a pre-`palette` binary keep the
  // old theme-derived approximation so an older CLI still paints something sane.
  function dirTarget(dir, base) {
    if (palette) {
      if (dir === "up") return paletteColor("up", base)
      if (dir === "down") return paletteColor("down", base)
      return base
    }
    if (dir === "up") return Commons.Color.accent
    if (dir === "down") return urgentColor
    return base
  }

  // Raw tint. BarWidget calls this directly for the strip, which has its own mono
  // setting, so the gating lives at each surface instead of in here. `strength`
  // defaults to landing ON the core's colour; the few chrome spots that want a
  // muted variant pass their own.
  function dirColorFor(dir, base, strength) {
    var b = base === undefined ? panelFg : base
    var target = dirTarget(dir, b)
    if (target === b) return b
    var t = strength === undefined ? (palette ? 1.0 : 0.62) : strength
    return t >= 1.0 ? target : mixColor(b, target, t)
  }

  // Panel-surface tint: foreground only when the panel is monochrome. Direction
  // stays readable through the signed change text, exactly like the CLI tooltip.
  function panelDirColor(dir, base, strength) {
    var b = base === undefined ? panelFg : base
    return panelColored ? dirColorFor(dir, b, strength) : b
  }

  // Accent/urgent carriers, resolved once so the mono branch is in one place. Both
  // prefer the core's palette, falling back to the shell theme for older documents.
  readonly property color panelAccent: panelColored ? paletteColor("accent", Commons.Color.accent) : panelFg
  readonly property color panelUrgent: panelColored ? paletteColor("error", urgentColor) : panelFg

  // ---- Compact bar strip model consumed by BarWidget.qml: the CLI-resolved
  //      curated subset (config `display.bar`, order preserved), optionally
  //      preceded by the watchlist-average summary.
  readonly property var barEntries: {
    if (!snapshot) return []
    var out = []
    var avg = snapshot.avg_change_pct
    if (showSummary && avg !== null && avg !== undefined) {
      var avgDir = avg > 0 ? "up" : (avg < 0 ? "down" : "flat")
      // The average is not an asset, so it carries no class mark — the sigma IS
      // its mark.
      out.push({ glyph: "", label: "Σ", value: changeText(avg, avgDir), dir: avgDir, muted: false })
    }
    // snapshot.bar carries the same raw row objects as the grouped table (already
    // selected and ordered by the CLI), so duplicate labels stay unambiguous.
    var barRows = snapshot.bar || []
    for (var i = 0; i < barRows.length; i++) {
      var r = barRows[i]
      var chg = changeText(r.change_pct, r.direction)
      out.push({
        // The class mark comes from the CLI (row.glyph, the same one the group
        // header carries), so the strip never re-derives which section an asset
        // belongs to. Empty string when the payload predates the field.
        glyph: String(r.glyph || ""),
        label: String(r.label),
        value: priceText(r) + (chg !== "" ? " " + chg : ""),
        dir: r.direction,
        muted: r.market === "closed"
      })
    }
    return out
  }

  // ---- Shared column widths, measured across ALL rows so every group's grid
  //      lines up like one table (the QML analogue of the tooltip's global
  //      column widths). Small buffer absorbs metric rounding.
  FontMetrics {
    id: fm
    font.family: root.panelFont
    font.pixelSize: Style.font.body
  }

  // Detail card: the label column is measured over the fixed label set, so the
  // values line up like the table's own columns.
  FontMetrics {
    id: detailLabelFm
    font.family: root.panelFont
    font.pixelSize: Style.font.body
  }

  readonly property real detailLabelW: {
    void detailLabelFm.font.pixelSize // re-measure when the font scale changes
    var labels = ["Price", "Day change", "Prev close", "Open", "Day range", "52w range",
                  "Amplitude", "Market", "Data", "P/E", "EPS", "Volume", "10d avg vol",
                  "Beta", "Div yield", "Shares out", "Exchange", "Name"]
    var w = 0
    for (var i = 0; i < labels.length; i++)
      w = Math.max(w, detailLabelFm.advanceWidth(labels[i]))
    return Math.ceil(w) + Style.space(8)
  }

  // ---- Currency per group: most groups are single-currency, so the code
  //      lives in the section header ("· ARS", muted) — repeating it on every
  //      row would be noise. Only a genuinely mixed group (crypto can quote
  //      usd and ars per asset) gets a minimal per-row code left of the price.
  function groupCurrencyInfo(g) {
    var known = []
    var rows = g && g.rows ? g.rows : []
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i]
      if (r.unit !== "currency") continue
      if (r.quote === null || r.quote === undefined || r.quote === "") continue
      var q = String(r.quote).toLowerCase()
      if (known.indexOf(q) === -1) known.push(q)
    }
    return { code: known.length === 1 ? known[0] : "", mixed: known.length > 1 }
  }

  // Any group mixing currencies right now? Gates the per-row currency column.
  readonly property bool anyMixedCurrency: {
    for (var i = 0; i < groups.length; i++) {
      if (groupCurrencyInfo(groups[i]).mixed) return true
    }
    return false
  }

  // Per-row currency cue, only inside mixed groups.
  function curCellText(r, groupMixed) {
    if (groupMixed !== true || r.unit !== "currency") return ""
    if (r.quote === null || r.quote === undefined || r.quote === "") return ""
    return String(r.quote).toLowerCase()
  }

  function columnWidth(kind) {
    var w = 0
    void fm.font.pixelSize // re-measure when the font scale changes
    for (var i = 0; i < groups.length; i++) {
      var g = groups[i]
      var mixed = groupCurrencyInfo(g).mixed
      var rows = g.rows || []
      for (var j = 0; j < rows.length; j++) {
        var r = rows[j]
        var text = kind === "label" ? String(r.label)
          : kind === "cur" ? curCellText(r, mixed)
          : kind === "price" ? priceText(r)
          : kind === "chg" ? chgCellText(r)
          : noteText(r, g.closed === true)
        w = Math.max(w, fm.advanceWidth(text))
      }
    }
    return Math.ceil(w) + Style.spaceReal(2)
  }

  readonly property real labelColW: columnWidth("label")
  readonly property real curColW: columnWidth("cur")
  readonly property real priceColW: columnWidth("price")
  readonly property real chgColW: columnWidth("chg")
  readonly property real noteColW: columnWidth("note")

  // Deterministic table geometry: every wrapped column is one 4-column grid of
  // the shared widths, so columns and bands align without measuring the scene —
  // and the card width is DERIVED from these measurements (content never paints
  // outside the panel; the note column is never elided).
  readonly property real colGap: Style.space(24)
  readonly property real rowIndent: Style.space(14)
  readonly property real gridW: labelColW + priceColW + chgColW + noteColW + Style.space(14) * 3
    + (anyMixedCurrency ? curColW + Style.space(14) : 0)

  // Widest group header ("<glyph> Name (source)"), measured bold — headers own
  // a full line above their rows, so a long provider list must also fit.
  FontMetrics {
    id: boldFm
    font.family: root.panelFont
    font.pixelSize: Style.font.title
    font.bold: true
  }

  function headerWidth() {
    var w = 0
    void boldFm.font.pixelSize // re-measure when the font scale changes
    for (var i = 0; i < groups.length; i++) {
      var g = groups[i]
      var t = String(g.glyph || "") + "  " + String(g.label) + "  (" + (g.sources || []).join("·") + ")"
      var cur = groupCurrencyInfo(g)
      if (cur.code !== "") t += "  · " + cur.code.toUpperCase()
      if (g.closed === true) t += "   closed"
      w = Math.max(w, boldFm.advanceWidth(t))
    }
    return Math.ceil(w) + Style.spaceReal(4)
  }

  readonly property real headerW: headerWidth()

  // A wrapped column is as wide as its indented grid or its widest header.
  readonly property real colW: Math.max(gridW + rowIndent, headerW)
  readonly property real tableW: {
    var maxCols = 0
    for (var i = 0; i < bands.length; i++) maxCols = Math.max(maxCols, bands[i].length)
    if (maxCols === 0) return Style.space(200)
    return maxCols * colW + (maxCols - 1) * colGap
  }

  // KeyboardPanel's contentWidth is the FULL card width (the content holder is
  // inset by padding + borders), so the card must add that inset around tableW.
  readonly property real cardWInset: panelSurface.padding * 2
    + Border.left(panelSurface.borderSpec) + Border.right(panelSurface.borderSpec)

  // Most side-by-side columns the screen can hold. When this cap bites, the
  // layout wraps into MORE bands (fewer columns each) instead of overflowing.
  readonly property int maxFitColumns: {
    var avail = panelSurface.availableCardWidth - cardWInset
    if (avail <= 0 || colW <= 0) return 1
    return Math.max(1, Math.floor((avail + colGap) / (colW + colGap)))
  }

  // ---- Auto-fit line budget: how many layout lines one column may hold on
  //      this screen. Pure MEASUREMENT — it is passed to the CLI as
  //      --rows-per-column, where the core packs with it (only when the
  //      config leaves tooltip_rows_per_column at 0). Measured heights:
  //        row line    = body line height + grid rowSpacing
  //        header line = title-bold line height + header->grid gap + the
  //                      inter-segment gap its section adds to the column
  //      The header share of a candidate column is bounded by the worst-case
  //      count of headers inside ANY window of that many consecutive lines
  //      (+1 for a possible continuation header), so tiny adjacent groups
  //      can't overflow the estimate. Iterates to a fixed point (shrinking
  //      the budget can only shrink the window's header count, so it
  //      converges monotonically).
  readonly property real rowUnitH: fm.height + Style.space(4)
  readonly property real headerUnitH: boldFm.height + Style.space(5) + Style.space(16)
  // Footer (separator + gaps + status line) reserved off the top of the budget.
  readonly property real footerReserveH: fm.height + Style.space(24)

  // ---- Summary chip + lifecycle status colors (theme-derived only).
  readonly property var summaryAvg: snapshot ? snapshot.avg_change_pct : null
  readonly property string summaryDir: typeof summaryAvg === "number"
    ? (summaryAvg > 0 ? "up" : (summaryAvg < 0 ? "down" : "flat")) : "flat"
  // The panel's average is ON by default, unlike the bar strip's. The two
  // surfaces have opposite constraints: the strip competes for bar width, so it
  // stays opt-in, while the hero has a slot reserved for exactly this and
  // "how is the watchlist doing overall" is the first thing a reader opening
  // the panel wants. `hide` is an explicit opt-out and still silences both.
  //
  // Read the chip for what it is: an UNWEIGHTED mean of each asset's daily
  // change. tickerbar models no holdings, so it cannot be a portfolio return —
  // BTC and a corporate bond count the same.
  readonly property bool summaryChipVisible: summaryMode !== "hide" && typeof summaryAvg === "number"

  // ---- Hero counts. The open/closed tally is not decoration: it is what
  //      explains why part of the table reads "closed" at a glance, which
  //      nothing else in the panel said.
  readonly property int assetCount: {
    var n = 0
    for (var i = 0; i < groups.length; i++) n += (groups[i].rows || []).length
    return n
  }
  readonly property int openGroupCount: {
    var n = 0
    for (var i = 0; i < groups.length; i++) if (groups[i].closed !== true) n++
    return n
  }
  readonly property string heroMeta: {
    if (assetCount === 0) return ""
    var parts = [assetCount + (assetCount === 1 ? " asset" : " assets")]
    if (groups.length > 0)
      parts.push(openGroupCount + " of " + groups.length
        + (groups.length === 1 ? " market" : " markets") + " open")
    return parts.join(" · ")
  }

  // Height the hero takes off the column budget. The summary chip used to own
  // this reserve on its own; it now rides in the hero's trailing slot, so the
  // hero is close to free whenever the chip is enabled and costs one line when
  // it is not. This panel is the densest of the family — the budget decides how
  // many rows fit per column, so hero chrome is paid for in rows.
  readonly property real heroReserveH: snapshot ? Style.font.display + Style.space(26) : 0

  readonly property color lifecycleColor: lifecycle === "error" || lifecycle === "partial"
    ? panelDirColor("down")
    : (lifecycle === "stale" ? mutedFg : panelDirColor("up", mutedFg, 0.8))

  // Worst-case count of header lines inside any window of `w` consecutive
  // layout lines, given the header line positions.
  function maxHeadersInWindow(headerPos, w) {
    var m = 0
    for (var a = 0; a < headerPos.length; a++) {
      var c = 0
      for (var b = a; b < headerPos.length && headerPos[b] < headerPos[a] + w; b++) c++
      if (c > m) m = c
    }
    return m
  }

  readonly property int autoLineBudget: {
    var headerPos = []
    var totalLines = 0
    for (var i = 0; i < groups.length; i++) {
      headerPos.push(totalLines)
      totalLines += 1 + (groups[i].rows || []).length
    }
    var avail = panelSurface.availableCardHeight - panelSurface.verticalContentInset - footerReserveH - heroReserveH
    if (totalLines === 0) {
      // No content yet (first run): optimistic row-only estimate minus a
      // small header reserve; the post-fetch measurement refines it.
      if (avail <= 0 || rowUnitH <= 0) return 40
      return Math.max(4, Math.floor(avail / rowUnitH) - 8)
    }
    if (avail <= 0 || rowUnitH <= 0) return totalLines

    var budget = Math.max(4, Math.floor(avail / rowUnitH)) // optimistic upper bound
    for (var it = 0; it < 6; it++) {
      var h = Math.min(headerPos.length + 1, maxHeadersInWindow(headerPos, budget) + 1) // +1 continuation
      var rowsFit = Math.floor((avail - h * headerUnitH) / rowUnitH)
      var next = Math.max(4, h + rowsFit)
      if (next >= budget) break
      budget = next
    }
    return budget
  }

  // ---- Packed layout, decided by the CORE (render::pack_columns — the exact
  //      code path that renders the waybar tooltip). The QML makes ZERO packing
  //      decisions: it measures its fit (autoLineBudget / maxFitColumns),
  //      passes the measurements to the CLI as --rows-per-column /
  //      --max-columns, and draws the bands -> columns -> segments the core
  //      returns (headers-never-orphaned, "(cont.)", banding all pre-decided).
  //      This only dereferences the plan into renderable objects.
  readonly property var bands: {
    if (!snapshot || !snapshot.layout || !snapshot.layout.bands) return []
    var out = []
    var plan = snapshot.layout.bands
    for (var b = 0; b < plan.length; b++) {
      var band = []
      for (var c = 0; c < plan[b].length; c++) {
        var col = []
        for (var s = 0; s < plan[b][c].length; s++) {
          var seg = plan[b][c][s]
          var g = groups[seg.group]
          if (!g) continue
          var cur = groupCurrencyInfo(g)
          col.push({
            label: String(g.label),
            glyph: String(g.glyph || ""),
            source: (g.sources || []).join("·"),
            closed: g.closed === true,
            continued: seg.continued === true,
            currency: cur.code,
            mixedCurrency: cur.mixed,
            rows: (g.rows || []).slice(seg.start, seg.start + seg.len)
          })
        }
        band.push(col)
      }
      out.push(band)
    }
    return out
  }

  // Flatten one group's rows into GridLayout cells (4 per row).
  function groupCells(rows, groupClosed, groupMixed) {
    var out = []
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i]
      var dim = r.market === "closed" || r.state === "missing" || r.state === "error"
      out.push({ kind: "label", text: String(r.label), dir: null, dim: dim })
      // The currency micro-column exists only while some group mixes currencies
      // (grid column count must stay uniform across every section).
      if (anyMixedCurrency)
        out.push({ kind: "cur", text: curCellText(r, groupMixed === true), dir: null, dim: true })
      out.push({ kind: "price", text: priceText(r), dir: r.direction, dim: dim })
      out.push({ kind: "chg", text: chgCellText(r), dir: r.direction, dim: dim })
      out.push({ kind: "note", text: noteText(r, groupClosed === true), dir: null, dim: true })
    }
    return out
  }

  // One entry per asset: the cells groupCells() produced for that row, so the
  // renderer can draw a row as ONE item that owns hover and a click.
  function groupRows(rows, groupClosed, groupMixed) {
    var cells = groupCells(rows, groupClosed, groupMixed)
    var cols = anyMixedCurrency ? 5 : 4
    var out = []
    for (var i = 0; i < rows.length; i++)
      out.push({
        row: rows[i],
        cells: cells.slice(i * cols, i * cols + cols)
      })
    return out
  }

  // Same mapping the GridLayout expressed as Layout.preferredWidth.
  function cellWidth(kind) {
    if (kind === "label") return labelColW
    if (kind === "cur") return curColW
    if (kind === "price") return priceColW
    if (kind === "chg") return chgColW
    return noteColW
  }

  // ---- Lifecycle: open/close/summon contract (same shape as weather).
  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  // Hide first: if the bar API ever rejects the setter again, the panel
  // still closes instead of stranding a full-screen overlay (tickerbar#1).
  function close() {
    // Reopening starts on the watchlist, never on a card from the last visit.
    root.selectedKey = ""
    root.controller.hide()
    setCenterHoverRevealSuppressed(false)
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  // The shell's base handler covers open/close/show/hide/toggle; this one adds
  // `refresh` so a keybind or a script can force a fetch without opening the
  // panel. Overriding means restating the five, so `manageIpc: false` above
  // turns the base one off and this is the only handler on the target.
  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Since omarchy 1702cf0 (2026-09-01) third-party widgets get a
  // PluginBarApi facade whose `centerHoverRevealSuppressed` is read-only;
  // the supported path is its setter. The assignment stays as a fallback
  // for older hosts that inject the real Bar. Either way a throw here must
  // not escape: close() calls this on every dismissal, openFromHotkey() on
  // every hotkey open.
  function setCenterHoverRevealSuppressed(value) {
    if (!root.bar) return
    try {
      if (typeof root.bar.setCenterHoverRevealSuppressed === "function")
        root.bar.setCenterHoverRevealSuppressed(value)
      else if ("centerHoverRevealSuppressed" in root.bar)
        root.bar.centerHoverRevealSuppressed = value
    } catch (e) {
      console.warn("setCenterHoverRevealSuppressed:", e)
    }
  }

  // ---- Data flow: poll the CLI, parse, keep last-known-good on any failure,
  //      and surface run failures explicitly (never a silent forever-loading).
  //      Exit and collector completion are joined before finalizing; a failed
  //      start (collector never fires) is bounded by the fallback timer.
  property bool collectorDone: true
  property bool processDone: true

  // A fetch is in flight. BOTH halves matter: the exit code and the collected
  // stdout arrive in either order, which is exactly why maybeFinalize() waits
  // for the pair. The refresh button gates on this, not on collectorDone alone
  // — otherwise it re-enables in the gap between the two signals and a click
  // there queues a second run through pendingCmd, which is the one thing its
  // disabled state promises cannot happen.
  readonly property bool fetchBusy: !collectorDone || !processDone
  property string capturedText: ""
  property int exitCode: 0
  property var pendingCmd: null

  // True when this run's collector refused oversize output. Its message
  // must survive finalizeRun; a stale error from a previous run must not.
  property bool tripwireFired: false

  // True when onExited fired for the current run. A missing command emits
  // no exited. This separates "could not start" from "ran, no output".
  property bool sawExit: false

  // True only when the run could not START. Gates the copy button.
  // Operational errors never set it.
  property bool notInstalled: false

  // One constant, two users: the error message shows it and the copy
  // button copies it.
  readonly property string installCmd: "yay -S tickerbar-bin"

  // The copy button shows a check for a moment.
  property bool installCopied: false
  Timer {
    id: copiedReset
    interval: 1500
    onTriggered: root.installCopied = false
  }

  function refresh() {
    startRun(buildCmd())
  }

  function startRun(cmd) {
    if (statusProc.running) { pendingCmd = cmd; return } // last-command-wins
    collectorDone = false
    processDone = false
    capturedText = ""
    sawExit = false
    tripwireFired = false
    exitCode = 0
    // Through sh, never direct: handing Quickshell 0.3.1 a nonexistent binary
    // can abort the whole shell inside the failed start (claudebar#6) — before
    // any QML signal fires. sh always starts; a failed exec is sh exiting 127
    // (not found) or 126 (not executable), which finalizeRun maps to the
    // failed-start path. "$0"/"$@" keep everything as argv elements.
    statusProc.command = ["/bin/sh", "-c", 'exec "$0" "$@"'].concat(cmd)
    statusProc.running = true
  }

  function maybeFinalize() {
    if (!collectorDone || !processDone) return
    exitFallback.stop()
    finalizeRun()
  }


  // Set when the plugin's own run fails, cleared by the next good parse. ORed
  // into the freshness state so a failure here reads like any other staleness.
  property bool pluginStale: false

  function setError(message) {
    runError = message
    // The last good payload stays on screen — deliberate — but it must stop
    // claiming to be current. Without this the footer keeps printing a plain
    // "Updated HH:MM" for data the CLI can no longer refresh.
    pluginStale = true
  }

  function finalizeRun() {
    notInstalled = false
    var text = capturedText.trim()
    if (text === "") {
      // Empty output has three causes. (1) The tripwire already set an
      // error: keep it. (2) No exited = failed start: report not-installed.
      // (3) The process ran and printed nothing: an operational error,
      // never "not installed".
      // A failed start is now sh exiting 126/127 (the exec failed; sh's
      // message goes to stderr, so stdout stays empty). !sawExit stays as
      // the belt for a start that emits no exited.
      if (tripwireFired) {
        // Already explained by this run's tripwire.
      } else if (!sawExit || exitCode === 126 || exitCode === 127) {
        notInstalled = true
        setError(binName + " could not start — not installed or not on PATH?\n\n"
                 + "Install it with:  " + installCmd + "\n"
                 + "Then open this panel again.")
      } else {
        setError(binName + " produced no output (exit " + exitCode + ")")
      }
    } else {
      handle(text)
    }
    if (pendingCmd) {
      var c = pendingCmd
      pendingCmd = null
      Qt.callLater(function() { root.startRun(c) })
    }
  }

  function handle(out) {
    // The CLI always exits 0 with a valid schema_version:1 document (errors ride
    // inside it as `error: {message}`), so anything else — waybar-shaped output,
    // truncated JSON — is an explicit error, while the last snapshot stays shown.
    try {
      var d = JSON.parse(out)
      if (!d || d.schema_version !== 1) {
        setError(binName + " returned an unexpected document (not schema_version 1)")
        return
      }
      // A structured failure with nothing to draw (config unreadable, internal error)
      // is the same situation as unparseable output: surface the message, but keep the
      // last good document on screen instead of blanking the table. A document that
      // still carries groups is a real (possibly partial) run and replaces it.
      var hasContent = d.groups && d.groups.length > 0
      if (d.error && d.error.message && !hasContent) {
        setError(String(d.error.message))
        return
      }
      root.snapshot = d
      root.runError = ""
      root.pluginStale = false
      // Fresh content can move the measured fit (row widths, group map). If it
      // differs from what this run was packed with, repack once — the second
      // run is cache-hot, and measurements are stable for identical content,
      // so this cannot loop.
      if (root.autoLineBudget !== root.lastSentBudget || root.maxFitColumns !== root.lastSentMaxCols)
        Qt.callLater(root.refresh)
    } catch (e) {
      setError(binName + " returned unparseable output"
        + (root.exitCode !== 0 ? " (exit " + root.exitCode + ")" : ""))
    }
  }

  Process {
    id: statusProc
    // A command that does not exist gives NEITHER `started` NOR `exited` —
    // Quickshell just drops `running` back to false. That is the only signal a
    // failed start emits, and without this handler the panel sits on its
    // loading text for ever: maybeFinalize() waits on processDone, which
    // nothing would ever set. This IS the first run of anyone who installed
    // the plugin from the marketplace and does not have the CLI yet.
    onRunningChanged: {
      if (running) return
      root.processDone = true
      exitFallback.restart()
      root.maybeFinalize()
    }
    onExited: function(code) {
      root.sawExit = true
      root.exitCode = code
      root.processDone = true
      exitFallback.restart() // failed-start case: the collector may never fire
      root.maybeFinalize()
    }
    stdout: StdioCollector {
      waitForEnd: true
      // A tripwire, not a limit, and it counts UTF-16 units rather than bytes —
      // QML's String.length has no byte view, so a megabyte of units is up to
      // three megabytes of UTF-8. StdioCollector has already buffered the whole
      // stream by the time this runs, so this cannot cap the peak memory — the
      // real bound is in the CLI, which reads every file and every response
      // under a byte cap of its own. What this does is refuse to RETAIN an
      // answer that could not have come from a healthy run, and say so, instead
      // of parsing megabytes of unknown text into the long-lived shell process.
      readonly property int maxChars: 1024 * 1024
      onStreamFinished: {
        if (text.length > maxChars) {
          root.tripwireFired = true
          root.capturedText = ""
          root.setError(root.binName + " returned more than " + (maxChars / 1024) + "K characters — refusing it")
        } else {
          root.capturedText = text
        }
        root.collectorDone = true
        root.maybeFinalize()
      }
    }
  }

  Timer {
    id: exitFallback
    interval: 300
    repeat: false
    onTriggered: {
      root.collectorDone = true // give up on the collector
      root.maybeFinalize()
    }
  }

  // ---- Second, independent process for the detail feed. A slow or dead CNBC
  //      must never stall the price table, so this shares nothing with
  //      statusProc beyond this panel's own properties. Exit and collector are
  //      joined the same way (either order), with the same failed-start belt.
  Process {
    id: detailProc
    onRunningChanged: {
      if (running) return
      root.detailProcessDone = true
      detailFallback.restart()
      root.maybeApplyDetail()
    }
    onExited: function(code) {
      root.detailExitCode = code
      root.detailProcessDone = true
      detailFallback.restart()
      root.maybeApplyDetail()
    }
    stdout: StdioCollector {
      waitForEnd: true
      // Same tripwire idea as the price run: a document this script can
      // produce is a few kilobytes, so anything near the cap is refused
      // rather than parsed into the long-lived shell process.
      readonly property int maxChars: 512 * 1024
      onStreamFinished: {
        root.detailCaptured = text.length > maxChars ? "" : text
        root.detailCollectorDone = true
        root.maybeApplyDetail()
      }
    }
  }

  Timer {
    id: detailFallback
    interval: 400
    repeat: false
    onTriggered: {
      root.detailCollectorDone = true // give up on the collector
      root.maybeApplyDetail()
    }
  }

  Timer {
    interval: root.refreshSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  KeyboardPanel {
    id: panelSurface
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    // Card width derived from the measured table (plus the card's own padding
    // and borders) so the panel always auto-fits its content; the screen-fit
    // clamp should never bite because maxFitColumns already wraps columns
    // into extra bands before that point.
    contentWidth: panelSurface.fittedContentWidth(root.tableW + root.cardWInset)
    contentHeight: panelSurface.fittedContentHeight(tickerColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Escape steps out of the detail card first, then closes the panel —
      // the same "back, then out" order the card's own arrow uses.
      onCloseRequested: root.selectedKey !== "" ? root.clearDetail() : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // No scrolling: like the waybar tooltip, long watchlists wrap into
      // side-by-side columns (and stacked bands), never a scrollbar.
      Column {
        id: tickerColumn
        spacing: Style.space(14)

        Text {
          textFormat: Text.PlainText
          visible: root.snapshot === null && root.topError === ""
          text: "Fetching prices…"
          color: root.mutedFg
          font.family: root.panelFont
          font.pixelSize: Style.font.bodySmall
          font.italic: true
        }

        // Error card (codexbar's pattern): quiet urgent-tinted surface instead
        // of a bare red line — readable without shouting.
        Rectangle {
          visible: root.topError !== ""
          width: root.tableW
          implicitHeight: errorText.implicitHeight + Style.space(14)
          radius: Style.cornerRadius
          color: Util.alpha(root.panelUrgent, 0.10)
          border.width: 1
          border.color: Util.alpha(root.panelUrgent, 0.30)

          Text {
            id: errorText
            anchors.left: parent.left
            anchors.right: copyInstallButton.visible ? copyInstallButton.left : parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            text: root.topError
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: root.mutedFg
            font.family: root.panelFont
            font.pixelSize: Style.font.bodySmall
          }

          // Copies installCmd as one argv element: no shell line, no
          // trailing newline. Gated on notInstalled, never on error text —
          // topError also carries CLI errors, and those get no button.
          PanelActionButton {
            id: copyInstallButton
            visible: root.notInstalled
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.installCopied ? "󰄬" : "󰆏"
            tooltipText: root.installCopied ? "Copied" : "Copy install command"
            foreground: root.mutedFg
            hoverColor: root.panelFg
            fontFamily: root.panelFont
            fontSize: Style.font.caption
            size: Style.space(20)
            onClicked: {
              Util.execArgv(["wl-copy", root.installCmd])
              root.installCopied = true
              copiedReset.restart()
            }
          }
        }

        // ---- Hero: the panel's identity line. Every sibling widget opens by
        //      naming itself; this one used to drop straight into a 71-row
        //      table with nothing saying what it was. The glyph is the class
        //      mark the stock rows already carry, in the theme accent —
        //      identity, never a gauge (see claudebar/codexbar/logibar).
        //
        //      The watchlist average rides in the trailing slot rather than
        //      becoming the hero's headline number. An equal-weighted mean
        //      across crypto, ARS bonds and treasuries is a mood, not a
        //      portfolio return, and printing it large would promise a
        //      precision it does not have.
        PanelHero {
          visible: root.snapshot !== null && root.selectedRow === null
          width: root.tableW
          title: "Watchlist"
          meta: root.heroMeta
          foreground: root.panelFg
          fontFamily: root.panelFont

          iconComponent: Component {
            Text {
              text: "" // nf-fa-line_chart
              textFormat: Text.PlainText
              color: root.panelAccent
              font.family: root.panelFont
              font.pixelSize: Style.font.display
            }
          }

          trailingControl: Component {
            Rectangle {
              visible: root.summaryChipVisible
              radius: height / 2
              implicitWidth: chipRow.implicitWidth + Style.space(20)
              implicitHeight: chipRow.implicitHeight + Style.space(9)
              color: Util.alpha(root.panelDirColor(root.summaryDir), 0.12)
              border.width: 1
              border.color: Util.alpha(root.panelDirColor(root.summaryDir), 0.32)

              Behavior on color { ColorAnimation { duration: 160 } }
              Behavior on border.color { ColorAnimation { duration: 160 } }

              Row {
                id: chipRow
                anchors.centerIn: parent
                spacing: Style.space(7)

                Text {
                  textFormat: Text.PlainText
                  id: chipValue
                  text: root.changeText(root.summaryAvg, root.summaryDir)
                  color: root.panelDirColor(root.summaryDir)
                  font.family: root.panelFont
                  font.pixelSize: Style.font.body
                  font.bold: true
                  renderType: Text.NativeRendering

                  Behavior on color { ColorAnimation { duration: 160 } }
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.baseline: chipValue.baseline
                  text: "avg"
                  color: root.mutedFg
                  font.family: root.panelFont
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        PanelSeparator {
          visible: root.snapshot !== null
          width: root.tableW
          foreground: root.panelFg
        }

        // ---- Detail card: one asset, opened by clicking its table row.
        //      Every number here is already in the row the table holds, so the
        //      card refreshes with the panel and costs no extra request. The
        //      back arrow (or Escape) returns to the watchlist.
        Column {
          id: detailColumn
          visible: root.selectedRow !== null
          width: root.tableW
          spacing: Style.space(14)

          PanelHero {
            width: root.tableW
            title: root.selectedRow ? String(root.selectedRow.label) : ""
            // The cap rides in the hero's pill: it is the one fundamental an
            // investor looks for before anything else, and a row in the table
            // below would bury it among P/E and beta.
            detail: root.detailMarketCapText
            meta: root.detailMeta
            foreground: root.panelFg
            fontFamily: root.panelFont

            iconComponent: Component {
              Text {
                text: root.detailGlyph
                textFormat: Text.PlainText
                color: root.panelAccent
                font.family: root.panelFont
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.space(4)

                PanelActionButton {
                  iconText: "󰏌" // nf-md-open_in_new
                  tooltipText: "Open quote page"
                  foreground: root.mutedFg
                  hoverColor: root.panelFg
                  fontFamily: root.panelFont
                  fontSize: Style.font.icon
                  onClicked: root.openQuote()
                }

                PanelActionButton {
                  // nf-md-content_copy / nf-md-check
                  iconText: root.symbolCopied ? "󰄬" : "󰆏"
                  tooltipText: root.symbolCopied ? "Copied" : "Copy symbol"
                  foreground: root.mutedFg
                  hoverColor: root.panelFg
                  fontFamily: root.panelFont
                  fontSize: Style.font.icon
                  enabled: root.detailSymbol !== ""
                  onClicked: root.copySymbol()
                }

                PanelActionButton {
                  iconText: "󰅁" // nf-md-chevron_left
                  tooltipText: "Back to watchlist"
                  foreground: root.mutedFg
                  hoverColor: root.panelFg
                  fontFamily: root.panelFont
                  fontSize: Style.font.icon
                  onClicked: root.clearDetail()
                }
              }
            }
          }

          // Headline: the price the row carries, with the day's move beside it
          // — the two numbers the table already ranks by.
          Row {
            spacing: Style.space(14)

            Text {
              id: detailPrice
              textFormat: Text.PlainText
              text: root.detailPriceText + root.detailCurrency
              color: root.panelFg
              font.family: root.panelFont
              font.pixelSize: Style.font.display
              font.bold: true
              renderType: Text.NativeRendering
            }

            Text {
              textFormat: Text.PlainText
              text: root.detailChangeText
              anchors.baseline: detailPrice.baseline
              color: root.detailDirColor
              font.family: root.panelFont
              font.pixelSize: Style.font.title
              font.bold: true
              renderType: Text.NativeRendering
            }
          }

          // Day range: the low and high the row carries, with the price marked
          // where it sits between them. Hidden when no range came back.
          Column {
            visible: root.detailRangePos >= 0
            width: root.tableW
            spacing: Style.space(5)

            Item {
              width: parent.width
              height: Style.space(12)

              Rectangle {
                id: rangeTrack
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: Style.space(3)
                radius: height / 2
                color: Util.alpha(root.panelFg, 0.14)
              }

              Rectangle {
                width: Style.space(6)
                height: Style.space(10)
                radius: width / 2
                x: Math.round((rangeTrack.width - width) * root.detailRangePos)
                anchors.verticalCenter: parent.verticalCenter
                color: root.detailDirColor
              }
            }

            Row {
              spacing: Style.space(10)

              Text {
                textFormat: Text.PlainText
                text: root.selectedRow && root.selectedRow.day_low !== null && root.selectedRow.day_low !== undefined
                  ? root.fmtNumber(root.selectedRow.day_low) : "—"
                color: root.mutedFg
                font.family: root.panelFont
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                text: "low – high"
                color: root.mutedFg
                font.family: root.panelFont
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                text: root.selectedRow && root.selectedRow.day_high !== null && root.selectedRow.day_high !== undefined
                  ? root.fmtNumber(root.selectedRow.day_high) : "—"
                color: root.mutedFg
                font.family: root.panelFont
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- Chart: OHLC candles from the detail feed. The three pills ask
          //      the SAME document for another range, so switching costs no
          //      request — the script returns 1D, 1W and 1Y together.
          Column {
            width: root.tableW
            spacing: Style.space(8)

            Row {
              spacing: Style.space(4)

              Repeater {
                model: ["1D", "1W", "1Y"]

                Rectangle {
                  id: rangePill
                  required property string modelData
                  readonly property bool active: root.detailRange === modelData

                  width: rangeLabel.implicitWidth + Style.space(16)
                  height: rangeLabel.implicitHeight + Style.space(5)
                  radius: height / 2
                  color: active ? Util.alpha(root.panelAccent, 0.16) : "transparent"
                  border.width: 1
                  border.color: active ? Util.alpha(root.panelAccent, 0.45) : Util.alpha(root.panelFg, 0.12)

                  Text {
                    id: rangeLabel
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: rangePill.modelData
                    color: rangePill.active ? root.panelFg : root.mutedFg
                    font.family: root.panelFont
                    font.pixelSize: Style.font.caption
                    font.bold: rangePill.active
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.detailRange = rangePill.modelData
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: root.detailChartStatus !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: root.detailChartStatus
                color: root.mutedFg
                font.family: root.panelFont
                font.pixelSize: Style.font.caption
              }
            }

            Item {
              width: root.tableW
              height: Style.space(132)

              Canvas {
                id: candleChart
                anchors.fill: parent

                property var candles: root.detailCandles
                property var bounds: root.detailBounds
                // Right band reserved for the two scale labels, so a candle
                // can never be drawn under a number.
                property real labelInset: Style.space(54)

                onCandlesChanged: requestPaint()
                onBoundsChanged: requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()

                onPaint: {
                  var ctx = getContext("2d")
                  ctx.clearRect(0, 0, width, height)

                  var data = candleChart.candles
                  var plotW = width - candleChart.labelInset
                  var padY = Style.space(6)
                  var plotH = height - padY * 2
                  if (!data || data.length === 0 || plotW <= 0 || plotH <= 0) return

                  var hi = candleChart.bounds.hi
                  var lo = candleChart.bounds.lo
                  if (!isFinite(hi) || !isFinite(lo)) return
                  if (hi === lo) { hi += 0.01; lo -= 0.01 }
                  var pad = (hi - lo) * 0.06
                  hi += pad
                  lo -= pad
                  var span = hi - lo

                  // Three hairlines: the top and bottom ones are the scale.
                  ctx.lineWidth = 1
                  ctx.strokeStyle = Util.alpha(root.panelFg, 0.08)
                  for (var g = 0; g <= 2; g++) {
                    var gy = Math.round(padY + plotH * (g / 2)) + 0.5
                    ctx.beginPath()
                    ctx.moveTo(0, gy)
                    ctx.lineTo(plotW, gy)
                    ctx.stroke()
                  }

                  var step = plotW / data.length
                  var bodyW = Math.max(1, Math.min(Style.space(9), step * 0.62))
                  var upColor = root.panelDirColor("up")
                  var downColor = root.panelDirColor("down")

                  for (var k = 0; k < data.length; k++) {
                    var c = data[k]
                    var cx = Math.round((k + 0.5) * step) + 0.5
                    var rising = Number(c.c) >= Number(c.o)
                    ctx.strokeStyle = rising ? upColor : downColor
                    ctx.fillStyle = rising ? upColor : downColor
                    ctx.lineWidth = Math.max(1, Math.min(2, step * 0.18))

                    var yHigh = padY + plotH * (1 - (Number(c.h) - lo) / span)
                    var yLow = padY + plotH * (1 - (Number(c.l) - lo) / span)
                    ctx.beginPath()
                    ctx.moveTo(cx, yHigh)
                    ctx.lineTo(cx, yLow)
                    ctx.stroke()

                    var yOpen = padY + plotH * (1 - (Number(c.o) - lo) / span)
                    var yClose = padY + plotH * (1 - (Number(c.c) - lo) / span)
                    var top = Math.min(yOpen, yClose)
                    var bodyH = Math.max(1, Math.abs(yClose - yOpen))
                    ctx.fillRect(cx - bodyW / 2, top, bodyW, bodyH)
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.topMargin: Style.space(1)
                visible: root.detailCandles.length > 0 && isFinite(root.detailBounds.hi)
                text: isFinite(root.detailBounds.hi) ? root.fmtNumber(root.detailBounds.hi) : ""
                color: root.mutedFg
                font.family: root.panelFont
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Style.space(1)
                visible: root.detailCandles.length > 0 && isFinite(root.detailBounds.lo)
                text: isFinite(root.detailBounds.lo) ? root.fmtNumber(root.detailBounds.lo) : ""
                color: root.mutedFg
                font.family: root.panelFont
                font.pixelSize: Style.font.caption
              }
            }
          }

          // Key/value block: session facts on the left, fundamentals on the
          // right. Two columns keep the card shorter than the table it
          // replaces instead of growing into a screen-tall list.
          Row {
            width: root.tableW
            spacing: Style.space(28)

            Column {
              spacing: Style.space(5)

              Repeater {
                model: root.detailRows

                Row {
                  required property var modelData
                  spacing: Style.space(12)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.label
                    width: root.detailLabelW
                    color: root.mutedFg
                    font.family: root.panelFont
                    font.pixelSize: Style.font.body
                    renderType: Text.NativeRendering
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.value
                    color: modelData.dir ? root.panelDirColor(modelData.dir) : root.panelFg
                    font.family: root.panelFont
                    font.pixelSize: Style.font.body
                    font.bold: modelData.strong === true
                    renderType: Text.NativeRendering
                  }
                }
              }
            }

            Column {
              visible: root.detailRowsRight.length > 0
              spacing: Style.space(5)

              Repeater {
                model: root.detailRowsRight

                Row {
                  required property var modelData
                  spacing: Style.space(12)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.label
                    width: root.detailLabelW
                    color: root.mutedFg
                    font.family: root.panelFont
                    font.pixelSize: Style.font.body
                    renderType: Text.NativeRendering
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.value
                    color: root.panelFg
                    font.family: root.panelFont
                    font.pixelSize: Style.font.body
                    renderType: Text.NativeRendering
                  }
                }
              }
            }
          }
        }

        // ---- Bands stacked vertically; inside a band, columns sit side by
        //      side; a column is a run of sections (header + aligned 4-column
        //      grid: label | price | change % | note). Every grid shares the
        //      global column widths, so the whole panel reads as one table.
        Repeater {
          model: root.bands

          Column {
            id: bandBlock
            required property var modelData
            required property int index
            // The detail card replaces the table; the bands collapse instead of
            // being destroyed, so `bands`, `tableW` and the card width keep
            // their values while a single asset is on screen.
            visible: root.selectedRow === null
            spacing: Style.space(14)

            PanelSeparator {
              visible: bandBlock.index > 0
              width: root.tableW
              foreground: root.panelFg
            }

            Row {
              spacing: root.colGap

              Repeater {
                model: bandBlock.modelData

                Item {
                  id: colBlock
                  required property var modelData
                  required property int index
                  width: root.colW
                  implicitHeight: colInner.implicitHeight

                  // Hairline between side-by-side columns — the QML analogue of
                  // the waybar tooltip's │ divider — centered in the gap and
                  // spanning the whole band's height.
                  Rectangle {
                    visible: colBlock.index > 0
                    x: -root.colGap / 2
                    width: 1
                    height: colBlock.parent ? colBlock.parent.height : colBlock.height
                    color: Util.alpha(root.panelFg, 0.10)
                  }

                  Column {
                    id: colInner
                    width: parent.width
                    spacing: Style.space(16)

                    Repeater {
                      model: colBlock.modelData

                      Column {
                        id: segBlock
                        required property var modelData
                        spacing: Style.space(5)

                        // Header line, same hierarchy as the waybar tooltip:
                        // accent class glyph + bold name at row size, muted
                        // "(source)" suffix, muted markers after it. Never
                        // smaller than the rows beneath.
                        Row {
                          spacing: Style.space(7)

                          Text {
                            text: String(segBlock.modelData.glyph || "")
                            textFormat: Text.PlainText
                            visible: text !== ""
                            color: root.panelAccent
                            anchors.baseline: sectionHeader.baseline
                            font.family: root.panelFont
                            font.pixelSize: Style.font.title
                            renderType: Text.NativeRendering
                          }

                          Text {
                            id: sectionHeader
                            // One step above the rows (title vs body): bold alone
                            // does not read as a header in a monospace face.
                            text: String(segBlock.modelData.label)
                            textFormat: Text.PlainText
                            color: root.panelFg
                            font.family: root.panelFont
                            font.pixelSize: Style.font.title
                            font.bold: true
                            renderType: Text.NativeRendering
                          }

                          Text {
                            visible: text !== "()"
                            text: "(" + String(segBlock.modelData.source || "") + ")"
                            textFormat: Text.PlainText
                            color: root.mutedFg
                            anchors.baseline: sectionHeader.baseline
                            font.family: root.panelFont
                            font.pixelSize: Style.font.body
                            renderType: Text.NativeRendering
                          }

                          // Section-wide currency: shown once here when every
                          // priced row in the group shares it (mixed groups get
                          // per-row codes in the grid instead).
                          Text {
                            visible: String(segBlock.modelData.currency || "") !== ""
                            text: "· " + String(segBlock.modelData.currency || "").toUpperCase()
                            textFormat: Text.PlainText
                            color: root.mutedFg
                            anchors.baseline: sectionHeader.baseline
                            font.family: root.panelFont
                            font.pixelSize: Style.font.body
                            renderType: Text.NativeRendering
                          }

                          Text {
                            textFormat: Text.PlainText
                            visible: segBlock.modelData.continued === true
                            anchors.baseline: sectionHeader.baseline
                            text: "(cont.)"
                            color: root.mutedFg
                            font.family: root.panelFont
                            font.pixelSize: Style.font.bodySmall
                          }

                          Text {
                            textFormat: Text.PlainText
                            visible: segBlock.modelData.closed === true
                            anchors.baseline: sectionHeader.baseline
                            text: "\uf04c closed"
                            color: root.mutedFg
                            font.family: root.panelFont
                            font.pixelSize: Style.font.bodySmall
                          }
                        }

                        // ---- Rows are items, not flattened GridLayout
                        //      cells: each asset owns one line, so it can
                        //      carry hover and a click. Column widths are the
                        //      shared measured ones, so the grid still aligns
                        //      with every other section; the 5px hover padding
                        //      is given back by the text inset.
                        Column {
                          x: root.rowIndent
                          spacing: Style.space(4)

                          Repeater {
                            model: root.groupRows(segBlock.modelData.rows || [], segBlock.modelData.closed, segBlock.modelData.mixedCurrency)

                            Rectangle {
                              id: assetRow
                              required property var modelData

                              x: -Style.space(5)
                              width: root.gridW + Style.space(10)
                              height: rowLine.implicitHeight
                              radius: Style.cornerRadius
                              // Row height stays exactly the text line: the
                              // panel's fit budget (rowUnitH) counts on it.
                              color: rowMouse.containsMouse ? Util.alpha(root.panelFg, 0.07) : "transparent"

                              Row {
                                id: rowLine
                                anchors.left: parent.left
                                anchors.leftMargin: Style.space(5)
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Style.space(14)

                                Repeater {
                                  model: assetRow.modelData.cells

                                  Text {
                                    required property var modelData
                                    text: modelData.text
                                    textFormat: Text.PlainText
                                    width: root.cellWidth(modelData.kind)
                                    color: modelData.dim ? root.mutedFg
                                      : (modelData.kind === "label" ? root.panelFg : root.panelDirColor(modelData.dir))
                                    font.family: root.panelFont
                                    font.pixelSize: Style.font.body
                                    renderType: Text.NativeRendering
                                    horizontalAlignment: modelData.kind === "price" || modelData.kind === "chg"
                                      ? Text.AlignRight : Text.AlignLeft
                                  }
                                }
                              }

                              // Click = "show me this one". The pointer shape is
                              // the only affordance: a hint glyph on every line
                              // would cost a column of width.
                              MouseArea {
                                id: rowMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: root.noteHover(assetRow.modelData.row)
                                onClicked: root.showDetail(assetRow.modelData.row)
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }

        // ---- Freshness footer: when the data is from, plus an inline
        //      refresh. The button re-runs the CLI right now — the same
        //      forced refresh the bar's middle-click does — so a stale panel
        //      can be corrected without closing it, and it is disabled while
        //      a fetch is already in flight so clicks cannot queue up. The
        //      rule and the row are always shown: the button has to stay
        //      reachable exactly when there is no timestamp to print yet.
        //
        //      The lifecycle suffix ("· stale", "· partial data") keeps its own
        //      tint so an unhealthy fetch still reads at a glance; the colored
        //      dot it replaces said the same thing without naming it.
        Column {
          // Same gap the card puts BELOW this line (popupPadding, 14), so the
          // footer sits centered between the rule and the card's bottom edge
          // instead of hugging the rule. It is also the outer column's own
          // rhythm, which is what the sibling widgets get for free by keeping
          // rule and footer as siblings in their main column.
          spacing: Style.space(14)

          PanelSeparator { width: root.tableW; foreground: root.panelFg }
          Item {
            width: root.tableW
            implicitHeight: Math.max(footerRow.implicitHeight, refreshButton.implicitHeight)

            Row {
              id: footerRow
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "󰅐  Updated " + (root.updatedText !== "" ? root.updatedText : "—")
                color: root.mutedFg
                font.family: root.panelFont
                font.pixelSize: Style.font.caption
              }

              Text {
                visible: root.lifecycle !== "" && root.lifecycle !== "ok"
                anchors.verticalCenter: parent.verticalCenter
                text: " · " + (root.lifecycle === "partial" ? "partial data" : root.lifecycle)
                textFormat: Text.PlainText
                // The family's freshness tint, NOT the market's down color:
                // "these prices are old" and "these prices fell" are unrelated
                // facts, and painting them the same red conflates them. Every
                // non-fresh lifecycle takes the same tone.
                color: root.freshnessWarn
                font.family: root.panelFont
                font.pixelSize: Style.font.caption
              }
            }

            PanelActionButton {
              id: refreshButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              // nf-md-refresh (U+F0450). Written literally: a JS "\\u" escape takes
              // exactly FOUR hex digits, so "\\uf0450" is U+F045 followed by a "0".
              iconText: "󰑐"
              tooltipText: "Refresh now"
              foreground: root.mutedFg
              hoverColor: root.panelFg
              fontFamily: root.panelFont
              fontSize: Style.font.caption
              size: Style.space(20)
              enabled: !root.fetchBusy
              onClicked: root.refresh()
            }
          }
        }
      }
    }
  }
}
