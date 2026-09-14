# GoldTrendEA — XAUUSD Expert Advisor for MetaTrader 5

A trend-following EA for gold, with ATR-scaled stops and percent-of-balance
position sizing.

> **This is a starting point, not a finished money-maker.** The default
> parameters are reasonable defaults, not optimised or validated values. Nobody
> has backtested this yet — see [Before you go live](#before-you-go-live).

---

## You cannot run this from your phone

The MT5 mobile app (iOS/Android) **cannot run Expert Advisors**. It has no
MetaEditor, no script engine, and no API. It is a manual-trading and monitoring
client only. That is a MetaQuotes limitation, not a settings problem.

To run this EA you need the **MT5 desktop terminal on Windows**, in one of
these arrangements:

| Setup | Runs 24/5? | Notes |
|---|---|---|
| Windows PC at home | Only while the PC is on and online | Free. Sleep/reboot kills the EA. |
| MetaQuotes VPS | Yes | Rented from inside the desktop terminal (Tools → Virtual Hosting). Cheapest path, but you need a desktop terminal **once** to set it up and migrate. |
| Third-party Windows VPS | Yes | Install MT5 yourself, full control, usually more expensive. |

Your phone's role is monitoring: log into the **same account** in the mobile
app and you'll see the EA's positions, stops and results live, and you can
close trades manually if you need to.

**If you have no access to a Windows machine at all, you cannot deploy this.**
Borrow one, use a cloud Windows VM, or talk to your broker about a
REST/FIX API instead (a different architecture entirely).

---

## Strategy

Entries are evaluated **only on closed bars**, so signals never repaint.

**Entry**
- Fast EMA (21) crosses the slow EMA (55) on the signal timeframe (default H1).
- Cross up → buy, cross down → sell.
- Trend filter (optional, on by default): the cross is only taken when the
  previous bar closed on the correct side of the 200 EMA. This keeps the EA out
  of counter-trend chop, which is where MA crossovers bleed worst on gold.

**Exit**
- Stop loss at `ATR(14) x 2.0`, take profit at `ATR(14) x 3.0` — so the stop
  widens automatically when gold is volatile and tightens when it is calm.
- Break-even: once price moves `1 x ATR` in your favour the stop is moved to
  the entry price.
- Trailing stop: `1.5 x ATR` behind price, and it only ever moves in your
  favour — never loosened.
- All positions are closed before the weekend (Friday 20:00 server time by
  default), because gold gaps over the weekend and a gap through your stop is
  an uncontrolled loss.

**Filters**
- Session filter: only trades 07:00–20:00 **broker server time** by default,
  covering the London and New York sessions where gold actually moves.
- Spread filter: skips entries when the spread exceeds 50 points. Gold spreads
  blow out around news releases, and an entry taken into a 200-point spread
  starts deep in the red.

## Risk controls

- **Position size** is computed from your balance, your risk percent, and the
  actual stop distance — using the broker's tick value, so it is correct for
  any account currency and contract size.
- Volume is always rounded **down** to the broker's lot step. If 1% risk works
  out smaller than the minimum lot, the EA **takes no trade** and logs why. It
  will never quietly round up and risk more than you told it to.
- Margin is checked before every entry; the trade is skipped if it would use
  more than 90% of free margin.
- `InpMaxDailyLossPct` (default 3%) halts **new** entries for the rest of the
  day once the account is down that much from the day's starting equity. Open
  positions keep their stops and trailing management.
- `InpMaxPositions` (default 1) caps concurrent positions.

> On a small account the minimum lot size may itself represent far more than 1%
> risk. Check the log on startup — if you see "below the broker minimum lot"
> repeatedly, your account is too small for this stop distance at this risk
> percent. Raising `InpRiskPercent` to force trades through is the wrong fix.

## Key parameters

| Input | Default | What it does |
|---|---|---|
| `InpTimeframe` | H1 | Signal timeframe. Lower timeframes on gold are mostly noise and spread. |
| `InpFastMAPeriod` / `InpSlowMAPeriod` | 21 / 55 | The crossover pair. Fast must be < slow. |
| `InpUseTrendFilter` / `InpTrendMAPeriod` | true / 200 | Long-term directional bias. |
| `InpATRStopMult` | 2.0 | Stop distance in ATR. Below ~1.5 on gold you get stopped out by normal noise. |
| `InpATRTargetMult` | 3.0 | Target distance in ATR. |
| `InpRiskPercent` | 1.0 | Risk per trade, % of balance. |
| `InpMaxDailyLossPct` | 3.0 | Daily loss circuit breaker. 0 disables. |
| `InpMaxSpreadPoints` | 50 | Max spread for entries. **Check your broker's typical gold spread and adjust.** |
| `InpSessionStartHour` / `InpSessionEndHour` | 7 / 20 | Trading window, **server time**. |
| `InpFridayCloseHour` | 20 | Flatten before the weekend. 0 disables. |
| `InpMagic` | 20260914 | Must be unique per EA instance. Two EAs sharing a magic number will manage each other's trades. |

### Server time is not your time

Every hour setting is in **broker server time**, which is often GMT+2 or GMT+3,
not your local time and not GMT. Check the clock in MT5's Market Watch, work
out your broker's offset, and adjust the session hours to match. Getting this
wrong is the single most common reason a session filter silently does nothing.

## Installation

1. Open **MT5 desktop** → `File` → `Open Data Folder`.
2. Copy `GoldTrendEA.mq5` into `MQL5/Experts/`.
3. Open **MetaEditor** (F4), find the file in the Navigator, press **F7** to
   compile. You should get `0 errors, 0 warnings`.
4. Back in the terminal, refresh the Navigator, then drag **GoldTrendEA** onto
   an **XAUUSD H1** chart.
5. In the dialog, on the *Common* tab, tick **Allow Algo Trading**. Set your
   inputs on the *Inputs* tab.
6. Make sure the **Algo Trading** button in the toolbar is green.

### Symbol names vary

Your broker may call gold `XAUUSD`, `XAUUSD.m`, `XAUUSDm`, `GOLD`, `GOLD.spot`
or similar. The EA trades whatever chart it is attached to and warns in the log
if the symbol doesn't look like gold. Attach it to *your* broker's gold chart —
don't rename anything.

## Before you go live

Do all four of these. In order.

1. **Backtest.** `View` → `Strategy Tester`, XAUUSD, H1, "Every tick based on
   real ticks", at least 2–3 years. Gold behaved very differently in 2019,
   2022 and 2024 — a strategy tuned on one regime often fails in the next.
2. **Read the report critically.** Look at maximum drawdown and the losing
   streaks, not the profit number. Ask whether you could actually sit through
   the worst drawdown without switching the EA off.
3. **Optimise carefully, if at all.** It is very easy to curve-fit the EMA
   periods to historical data and produce a backtest that means nothing.
   Prefer parameters that work acceptably across a *range* of values over a
   single sharp peak.
4. **Forward-test on a demo account for several weeks** with the same settings
   you intend to trade. Demo execution isn't identical to live, but it catches
   configuration mistakes, session-time errors and spread-filter problems
   before they cost money.

Only then consider a live account, starting at the smallest size your broker
allows.

## Honest limitations

- **This code has not been compiled or backtested.** It was written outside
  MetaTrader, and there is no MT5/Windows environment available here to verify
  it. Compile it yourself and read the Experts and Journal tabs for errors.
- **No news filter.** Gold reacts violently to FOMC, CPI and NFP. The spread
  filter blocks entries during the worst of it, but an already-open position is
  exposed. Consider standing the EA down manually around major releases.
- **No slippage or gap protection beyond the stop.** In a fast market your stop
  can fill worse than its level, so the realised loss can exceed the configured
  risk percent.
- **MA crossovers are a well-known, heavily-arbitraged idea.** The edge here, if
  any, comes from the risk management and filters, not the entry signal. Do not
  expect the entry alone to be profitable.
- The daily loss limit is measured against **equity at the start of the server
  day**, not a rolling window.

## Changing the strategy

The entry logic is isolated in `GetSignal()`, which returns `+1`, `-1` or `0`.
To trade a different idea — a breakout, an RSI setup, your own rules — replace
the body of that one function. Sizing, stops, trailing, filters and the safety
rails all keep working unchanged.
