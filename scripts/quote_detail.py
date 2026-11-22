#!/usr/bin/env python3
"""Per-symbol detail feed for the tickerbar Omarchy panel.

Two CNBC public endpoints, the same provider that already backs the panel's
prices (so the symbols match exactly, no second symbol vocabulary):

  * restQuote (fund=1)  - name, market cap, P/E, 52-week range, volume, ...
  * ts-api charts/1M    - ~250 daily OHLC bars (the year view)
  * ts-api charts/5D    - minute OHLC bars over the last 5 sessions (1D / 1W)

All chart timestamps from CNBC are US Eastern; the script only ever publishes
dates (MM-DD) and clock times, never a timezone claim.

Usage:  quote_detail.py --symbol AAPL
Output: one JSON document on stdout, always exit 0:

  {"schema": 1, "symbol": "AAPL", "error": null,
   "quote": {...},
   "ranges": {"1D": {"label": "2026-11-20", "candles": [...]},
              "1W": {...}, "1Y": {...}}}

A failure rides inside the document (`error`), because the caller must not
distinguish "no data" from "crashed": both draw the same quiet line.
"""

import argparse
import json
import sys
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta

UA = "Mozilla/5.0 (X11; Linux x86_64) tickerbar-detail/1"
QUOTE_URL = "https://quote.cnbc.com/quote-html-webservice/restQuote/symbolType/symbol"
CHART_URL = "https://ts-api.cnbc.com/harmony/app/charts/{range}.json?symbol={symbol}"
TIMEOUT = 12


def get_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def num(value):
    """'69,422,613' / '1,234.5' -> float, or None when it is not a number."""
    if value is None:
        return None
    text = str(value).strip().replace(",", "").replace("$", "")
    try:
        parsed = float(text)
    except ValueError:
        return None
    return parsed if parsed == parsed and abs(parsed) != float("inf") else None


def text(value):
    """Empty strings from the feed mean "unknown", not "empty"."""
    if value is None:
        return None
    stripped = str(value).strip()
    return stripped or None


def fetch_quote(symbol):
    params = urllib.parse.urlencode({
        "symbols": symbol,
        "requestMethod": "itv",
        "noform": "1",
        "output": "json",
        "fund": "1",
    })
    doc = get_json(QUOTE_URL + "?" + params)
    rows = (doc.get("FormattedQuoteResult") or {}).get("FormattedQuote") or []
    if not rows:
        return None
    row = rows[0]
    if row.get("code") not in (None, 0, "0") and not row.get("last"):
        return None
    return {
        "name": text(row.get("name")),
        "marketCap": text(row.get("mktcapView")),
        "pe": num(row.get("pe")),
        "eps": num(row.get("eps")),
        "divYield": text(row.get("dividendyield")),
        "beta": num(row.get("beta")),
        "volume": num(row.get("volume")),
        "avgVolume": text(row.get("tendayavgvol")),
        "yrHigh": num(row.get("yrhiprice")),
        "yrLow": num(row.get("yrloprice")),
        "open": num(row.get("open")),
        "prevClose": num(row.get("previous_day_closing")),
        "marketStatus": text(row.get("curmktstatus")),
        "currency": text(row.get("currencyCode")),
        "assetType": text(row.get("type")),
        "exchange": text(row.get("exchange")),
        "sharesOut": text(row.get("sharesout")),
    }


def fetch_bars(symbol, symbol_range):
    doc = get_json(CHART_URL.format(
        range=symbol_range, symbol=urllib.parse.quote(symbol, safe="")))
    bars = ((doc.get("barData") or {}).get("priceBars")) or []
    out = []
    for bar in bars:
        stamp = str(bar.get("tradeTime") or "")
        if len(stamp) != 14:
            continue
        try:
            values = {
                "t": stamp,
                "o": float(bar["open"]),
                "h": float(bar["high"]),
                "l": float(bar["low"]),
                "c": float(bar["close"]),
                "v": float(bar.get("volume") or 0),
            }
        except (KeyError, TypeError, ValueError):
            continue
        if values["h"] < values["l"]:
            values["h"], values["l"] = values["l"], values["h"]
        out.append(values)
    return out


def aggregate(bars, minutes):
    """Fold minute bars into `minutes`-wide buckets, never across a session."""
    if minutes <= 0:
        return bars
    buckets = []
    current = None
    current_key = None
    for bar in bars:
        stamp = bar["t"]
        day, hour, minute = stamp[:8], int(stamp[8:10]), int(stamp[10:12])
        key = "%s%02d%02d" % (day, hour, (minute // minutes) * minutes)
        if key != current_key:
            if current:
                buckets.append(current)
            current = {"t": key, "o": bar["o"], "h": bar["h"], "l": bar["l"],
                       "c": bar["c"], "v": bar["v"]}
            current_key = key
        else:
            current["h"] = max(current["h"], bar["h"])
            current["l"] = min(current["l"], bar["l"])
            current["c"] = bar["c"]
            current["v"] += bar["v"]
    if current:
        buckets.append(current)
    return buckets


def date_label(stamp):
    return "%s-%s-%s" % (stamp[0:4], stamp[4:6], stamp[6:8])


def clock_label(stamp):
    return "%s:%s" % (stamp[8:10], stamp[10:12])


def parse_stamp(stamp):
    return datetime.strptime(stamp, "%Y%m%d%H%M%S")


def last_session(bars):
    """The trailing 24 hours of bars.

    Calendar-day grouping cannot cut a session out of this feed: CNBC stamps
    everything in US Eastern, so an A-share session (08:58-15:13 CST) starts
    on one Eastern date and ends on the next, and a US day now includes the
    overnight feed. A 24-hour window from the newest bar lands on exactly one
    session for every market here - one full A-share day is 5.5 hours, one US
    day is 24 - and never splits one in half."""
    if not bars:
        return []
    end = parse_stamp(bars[-1]["t"])
    start = end - timedelta(hours=24)
    picked = [bar for bar in bars if parse_stamp(bar["t"]) >= start]
    if len(picked) < 3:
        picked = bars[-30:]
    return picked


def affordable(bars, target=90):
    """Bucket just enough that the chart stays readable at panel width.

    A US session arrives as ~193 bars (it now includes the overnight feed), an
    A-share session as ~25 to 50; the same rule has to serve both, so the step
    is chosen from the data instead of from a per-market table."""
    for minutes in (5, 10, 15, 30, 60, 120, 180, 240, 480):
        folded = aggregate(bars, minutes)
        if len(folded) <= target:
            return folded
    return aggregate(bars, 480)


def shape(bars, labels):
    out = []
    for bar in bars:
        stamp = bar["t"]
        out.append({
            "t": clock_label(stamp) if labels == "clock" else date_label(stamp + "000000"[len(stamp):]),
            "o": round(bar["o"], 4), "h": round(bar["h"], 4),
            "l": round(bar["l"], 4), "c": round(bar["c"], 4),
            "v": round(bar["v"], 2),
        })
    return out


def build(symbol):
    doc = {"schema": 1, "symbol": symbol, "error": None,
           "quote": None, "ranges": {}}

    # Three independent requests. They run together because the network here
    # takes seconds per call: serially the card sat on "Loading" for ten, in
    # parallel it is one round trip.
    quote = intraday = daily = None
    failures = []
    with ThreadPoolExecutor(max_workers=3) as pool:
        job_quote = pool.submit(fetch_quote, symbol)
        job_intraday = pool.submit(fetch_bars, symbol, "5D")
        job_daily = pool.submit(fetch_bars, symbol, "1M")  # ~250 daily bars
        for name, job in (("quote", job_quote), ("intraday", job_intraday),
                          ("daily", job_daily)):
            try:
                result = job.result(timeout=TIMEOUT + 4)
                if name == "quote":
                    quote = result
                elif name == "intraday":
                    intraday = result
                else:
                    daily = result
            except Exception as exc:  # noqa: BLE001 - the document stays valid
                failures.append("%s: %s" % (name, exc))

    doc["quote"] = quote

    if intraday:
        today = last_session(intraday)
        if today:
            doc["ranges"]["1D"] = {
                "label": "last session",
                "candles": shape(affordable(today, 90), "clock"),
            }
        doc["ranges"]["1W"] = {"label": "5 sessions",
                               "candles": shape(affordable(intraday, 90), "clock")}
    if daily:
        doc["ranges"]["1Y"] = {"label": "1 year", "candles": shape(daily, "date")}

    if failures and not doc["ranges"]:
        doc["error"] = "; ".join(failures)
    elif not doc["ranges"] and doc["error"] is None:
        doc["error"] = "no chart data for %s" % symbol
    return doc


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--symbol", required=True)
    args = parser.parse_args()
    try:
        doc = build(args.symbol.strip())
    except Exception as exc:  # noqa: BLE001 - never crash the panel
        doc = {"schema": 1, "symbol": args.symbol, "error": str(exc),
               "quote": None, "ranges": {}}
    json.dump(doc, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
