//+------------------------------------------------------------------+
//|                                                  GoldTrendEA.mq5 |
//|            Trend-following Expert Advisor for XAUUSD (gold)      |
//+------------------------------------------------------------------+
#property version   "1.00"
#property description "Trend-following EA for XAUUSD (gold)."
#property description "EMA cross entries, ATR-scaled stops, percent-of-balance sizing."
#property description "Test on a DEMO account and backtest before risking real money."

#include <Trade\Trade.mqh>

//=========================== INPUTS ================================
input group "=== Strategy ==="
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_H1;  // Signal timeframe
input int             InpFastMAPeriod     = 21;         // Fast EMA period
input int             InpSlowMAPeriod     = 55;         // Slow EMA period
input bool            InpUseTrendFilter   = true;       // Only trade with the long-term trend
input int             InpTrendMAPeriod    = 200;        // Trend filter EMA period
input int             InpATRPeriod        = 14;         // ATR period
input double          InpATRStopMult      = 2.0;        // Stop loss = ATR x this
input double          InpATRTargetMult    = 3.0;        // Take profit = ATR x this

input group "=== Risk ==="
input double          InpRiskPercent      = 1.0;        // Risk per trade (% of balance)
input double          InpMaxLot           = 0.0;        // Hard lot cap (0 = broker max)
input int             InpMaxPositions     = 1;          // Max concurrent positions
input double          InpMaxDailyLossPct  = 3.0;        // Halt new entries after this daily loss % (0 = off)

input group "=== Trade management ==="
input bool            InpUseBreakEven     = true;       // Move stop to entry once in profit
input double          InpBreakEvenATRMult = 1.0;        // Break-even trigger = ATR x this
input bool            InpUseTrailing      = true;       // Trail the stop
input double          InpTrailATRMult     = 1.5;        // Trail distance = ATR x this

input group "=== Filters ==="
input bool            InpUseSessionFilter = true;       // Restrict trading hours
input int             InpSessionStartHour = 7;          // Session start hour (BROKER server time)
input int             InpSessionEndHour   = 20;         // Session end hour (BROKER server time)
input int             InpFridayCloseHour  = 20;         // Close all + stop on Friday at this hour (0 = off)
input int             InpMaxSpreadPoints  = 50;         // Skip entries above this spread in points (0 = off)

input group "=== Execution ==="
input ulong           InpMagic            = 20260914;   // Magic number (unique per EA instance)
input int             InpSlippagePoints   = 30;         // Max slippage in points
input string          InpTradeComment     = "GoldTrendEA"; // Order comment
input bool            InpVerboseLog       = true;       // Log decisions to the Experts tab

//=========================== GLOBALS ===============================
CTrade   g_trade;
int      g_hFast  = INVALID_HANDLE;
int      g_hSlow  = INVALID_HANDLE;
int      g_hTrend = INVALID_HANDLE;
int      g_hATR   = INVALID_HANDLE;

double   g_point         = 0.0;
int      g_digits        = 0;
datetime g_lastBarTime   = 0;
datetime g_dayAnchor     = 0;
double   g_dayStartEquity = 0.0;
bool     g_haltedToday   = false;

//+------------------------------------------------------------------+
//| Initialisation                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(g_point <= 0.0)
     {
      Print("ERROR: could not read symbol point size for ", _Symbol);
      return(INIT_FAILED);
     }
   if(InpFastMAPeriod >= InpSlowMAPeriod)
     {
      Print("ERROR: fast EMA period must be smaller than slow EMA period.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 10.0)
     {
      Print("ERROR: risk percent must be between 0 and 10.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpATRStopMult <= 0.0 || InpATRTargetMult <= 0.0)
     {
      Print("ERROR: ATR stop and target multipliers must be positive.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpMaxPositions < 1)
     {
      Print("ERROR: max positions must be at least 1.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_hFast  = iMA(_Symbol, InpTimeframe, InpFastMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hSlow  = iMA(_Symbol, InpTimeframe, InpSlowMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hTrend = iMA(_Symbol, InpTimeframe, InpTrendMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hATR   = iATR(_Symbol, InpTimeframe, InpATRPeriod);

   if(g_hFast == INVALID_HANDLE || g_hSlow == INVALID_HANDLE ||
      g_hTrend == INVALID_HANDLE || g_hATR == INVALID_HANDLE)
     {
      Print("ERROR: failed to create indicator handles.");
      return(INIT_FAILED);
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.LogLevel(InpVerboseLog ? LOG_LEVEL_ERRORS : LOG_LEVEL_NO);

   string sym = _Symbol;
   StringToUpper(sym);
   if(StringFind(sym, "XAU") < 0 && StringFind(sym, "GOLD") < 0)
      Print("WARNING: this EA was tuned for XAUUSD but is running on ", _Symbol,
            ". Re-check the ATR multipliers and spread filter before trading.");

   ResetDayAnchor();
   Print("GoldTrendEA initialised on ", _Symbol, " ", EnumToString(InpTimeframe),
         " | risk ", DoubleToString(InpRiskPercent, 2), "% per trade");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Shutdown                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_hFast  != INVALID_HANDLE) IndicatorRelease(g_hFast);
   if(g_hSlow  != INVALID_HANDLE) IndicatorRelease(g_hSlow);
   if(g_hTrend != INVALID_HANDLE) IndicatorRelease(g_hTrend);
   if(g_hATR   != INVALID_HANDLE) IndicatorRelease(g_hATR);
  }

//+------------------------------------------------------------------+
//| Main tick handler                                                |
//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateDayAnchor();

   double atr = 0.0;
   if(!CopyOne(g_hATR, 1, atr) || atr <= 0.0)
      return;

   // Weekend protection: flatten and stand down before the Friday close.
   if(IsFridayCutoff())
     {
      if(CountOwnPositions() > 0)
        {
         if(InpVerboseLog) Print("Friday cutoff reached - closing open positions.");
         CloseAllOwnPositions();
        }
      return;
     }

   ManageOpenPositions(atr);

   if(g_haltedToday)                          return;
   if(!IsNewBar())                            return;
   if(!SessionAllows())                       return;
   if(!SpreadOK())                            return;
   if(CountOwnPositions() >= InpMaxPositions) return;

   int signal = GetSignal();
   if(signal == 0)
      return;

   OpenTrade(signal, atr);
  }

//+------------------------------------------------------------------+
//| Read a single indicator value at the given bar shift             |
//+------------------------------------------------------------------+
bool CopyOne(const int handle, const int shift, double &value)
  {
   if(handle == INVALID_HANDLE)
      return(false);
   double buf[];
   if(CopyBuffer(handle, 0, shift, 1, buf) < 1)
      return(false);
   value = buf[0];
   return(true);
  }

//+------------------------------------------------------------------+
//| True once per completed bar on the signal timeframe              |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t = iTime(_Symbol, InpTimeframe, 0);
   if(t == 0 || t == g_lastBarTime)
      return(false);
   g_lastBarTime = t;
   return(true);
  }

//+------------------------------------------------------------------+
//| Entry signal: +1 buy, -1 sell, 0 none                            |
//| Evaluated on closed bars 1 and 2 so signals never repaint.       |
//+------------------------------------------------------------------+
int GetSignal()
  {
   double fast1, fast2, slow1, slow2;
   if(!CopyOne(g_hFast, 1, fast1) || !CopyOne(g_hFast, 2, fast2)) return(0);
   if(!CopyOne(g_hSlow, 1, slow1) || !CopyOne(g_hSlow, 2, slow2)) return(0);

   bool crossUp   = (fast2 <= slow2 && fast1 > slow1);
   bool crossDown = (fast2 >= slow2 && fast1 < slow1);
   if(!crossUp && !crossDown)
      return(0);

   if(InpUseTrendFilter)
     {
      double trend1;
      if(!CopyOne(g_hTrend, 1, trend1))
         return(0);
      double close1 = iClose(_Symbol, InpTimeframe, 1);
      if(close1 <= 0.0)
         return(0);
      if(crossUp   && close1 <= trend1) return(0);
      if(crossDown && close1 >= trend1) return(0);
     }

   return(crossUp ? 1 : -1);
  }

//+------------------------------------------------------------------+
//| Open a position with ATR stops and risk-based volume             |
//+------------------------------------------------------------------+
void OpenTrade(const int dir, const double atr)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return;

   double price   = (dir > 0) ? ask : bid;
   double minDist = MinStopDistance();
   double slDist  = MathMax(atr * InpATRStopMult,   minDist);
   double tpDist  = MathMax(atr * InpATRTargetMult, minDist);

   double sl = NormalizeDouble((dir > 0) ? price - slDist : price + slDist, g_digits);
   double tp = NormalizeDouble((dir > 0) ? price + tpDist : price - tpDist, g_digits);

   double lots = CalcLots(slDist, dir, price);
   if(lots <= 0.0)
      return;

   bool ok = (dir > 0)
             ? g_trade.Buy(lots, _Symbol, price, sl, tp, InpTradeComment)
             : g_trade.Sell(lots, _Symbol, price, sl, tp, InpTradeComment);

   if(!ok)
      PrintFormat("Order failed: retcode=%d (%s)",
                  g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   else if(InpVerboseLog)
      PrintFormat("Opened %s %.2f lots @ %.*f | SL %.*f | TP %.*f | ATR %.*f",
                  (dir > 0 ? "BUY" : "SELL"), lots,
                  g_digits, price, g_digits, sl, g_digits, tp, g_digits, atr);
  }

//+------------------------------------------------------------------+
//| Volume from risk percent and stop distance                       |
//+------------------------------------------------------------------+
double CalcLots(const double slDistPrice, const int dir, const double price)
  {
   if(slDistPrice <= 0.0)
      return(0.0);

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;
   if(riskMoney <= 0.0)
      return(0.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0.0)
      tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0)
      tickSize = g_point;
   if(tickValue <= 0.0 || tickSize <= 0.0)
     {
      Print("Skip: broker did not report usable tick value/size for ", _Symbol);
      return(0.0);
     }

   double lossPerLot = (slDistPrice / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return(0.0);

   double lots = NormalizeLots(riskMoney / lossPerLot);
   if(lots <= 0.0)
     {
      if(InpVerboseLog)
         PrintFormat("Skip: %.2f%% risk on a %.2f stop is below the broker minimum lot.",
                     InpRiskPercent, slDistPrice);
      return(0.0);
     }

   double margin = 0.0;
   ENUM_ORDER_TYPE type = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(OrderCalcMargin(type, _Symbol, lots, price, margin))
     {
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(margin > freeMargin * 0.9)
        {
         PrintFormat("Skip: margin %.2f exceeds 90%% of free margin %.2f", margin, freeMargin);
         return(0.0);
        }
     }

   return(lots);
  }

//+------------------------------------------------------------------+
//| Round volume DOWN to the broker's lot step (never round up:      |
//| rounding up would exceed the configured risk)                    |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
  {
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;
   if(InpMaxLot > 0.0)
      maxLot = MathMin(maxLot, InpMaxLot);

   lots = MathFloor(lots / step) * step;
   lots = NormalizeDouble(lots, VolumeDigits());

   if(lots < minLot) return(0.0);
   if(lots > maxLot) lots = NormalizeDouble(maxLot, VolumeDigits());
   return(lots);
  }

//+------------------------------------------------------------------+
//| Decimal places implied by the broker's lot step                  |
//+------------------------------------------------------------------+
int VolumeDigits()
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      return(2);
   int d = 0;
   while(step < 1.0 && d < 8)
     {
      step *= 10.0;
      d++;
     }
   return(d);
  }

//+------------------------------------------------------------------+
//| Minimum legal distance between price and a stop order            |
//+------------------------------------------------------------------+
double MinStopDistance()
  {
   double stops  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double freeze = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double broker = MathMax(stops, freeze) * g_point;
   // Many brokers report 0 and apply a dynamic level instead: keep a spread-based floor.
   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * g_point;
   return(MathMax(broker, spread * 2.0));
  }

//+------------------------------------------------------------------+
//| Break-even and trailing stop maintenance                         |
//+------------------------------------------------------------------+
void ManageOpenPositions(const double atr)
  {
   if(!InpUseBreakEven && !InpUseTrailing)
      return;

   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minDist = MinStopDistance();
   if(bid <= 0.0 || ask <= 0.0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)                                          continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)        continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      long   type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double cur  = (type == POSITION_TYPE_BUY) ? bid : ask;

      bool beReady = InpUseBreakEven && InpBreakEvenATRMult > 0.0 &&
                     ((type == POSITION_TYPE_BUY)
                      ? (cur - open) >= atr * InpBreakEvenATRMult
                      : (open - cur) >= atr * InpBreakEvenATRMult);

      double candidate;
      if(type == POSITION_TYPE_BUY)
        {
         candidate = sl;
         if(beReady)
            candidate = MathMax(candidate, open);
         if(InpUseTrailing && InpTrailATRMult > 0.0)
            candidate = MathMax(candidate, cur - atr * InpTrailATRMult);

         candidate = NormalizeDouble(candidate, g_digits);
         if(candidate <= sl + g_point * 0.5) continue;   // never loosen an existing stop
         if(candidate >= cur - minDist)      continue;   // too close to market
        }
      else
        {
         candidate = (sl > 0.0) ? sl : DBL_MAX;
         if(beReady)
            candidate = MathMin(candidate, open);
         if(InpUseTrailing && InpTrailATRMult > 0.0)
            candidate = MathMin(candidate, cur + atr * InpTrailATRMult);
         if(candidate == DBL_MAX) continue;

         candidate = NormalizeDouble(candidate, g_digits);
         if(sl > 0.0 && candidate >= sl - g_point * 0.5) continue;
         if(candidate <= cur + minDist)                  continue;
        }

      if(!g_trade.PositionModify(ticket, candidate, tp))
         PrintFormat("Stop update failed on #%I64u: retcode=%d (%s)",
                     ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      else if(InpVerboseLog)
         PrintFormat("Stop moved on #%I64u to %.*f", ticket, g_digits, candidate);
     }
  }

//+------------------------------------------------------------------+
//| Count positions owned by this EA on this symbol                  |
//+------------------------------------------------------------------+
int CountOwnPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)                                          continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)        continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Close every position owned by this EA on this symbol             |
//+------------------------------------------------------------------+
void CloseAllOwnPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)                                          continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)        continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(!g_trade.PositionClose(ticket))
         PrintFormat("Close failed on #%I64u: retcode=%d (%s)",
                     ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Trading-hours filter (broker server time, not your local time)   |
//+------------------------------------------------------------------+
bool SessionAllows()
  {
   if(!InpUseSessionFilter)
      return(true);

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == SATURDAY || dt.day_of_week == SUNDAY)
      return(false);

   if(InpSessionStartHour == InpSessionEndHour)
      return(true);
   if(InpSessionStartHour < InpSessionEndHour)
      return(dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour);
   return(dt.hour >= InpSessionStartHour || dt.hour < InpSessionEndHour); // wraps midnight
  }

//+------------------------------------------------------------------+
//| Friday stand-down check                                          |
//+------------------------------------------------------------------+
bool IsFridayCutoff()
  {
   if(InpFridayCloseHour <= 0)
      return(false);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return(dt.day_of_week == FRIDAY && dt.hour >= InpFridayCloseHour);
  }

//+------------------------------------------------------------------+
//| Spread filter - gold spreads widen sharply around news           |
//+------------------------------------------------------------------+
bool SpreadOK()
  {
   if(InpMaxSpreadPoints <= 0)
      return(true);
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPoints)
     {
      if(InpVerboseLog)
         PrintFormat("Skip: spread %d points above limit %d", (int)spread, InpMaxSpreadPoints);
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Daily loss guard                                                 |
//+------------------------------------------------------------------+
void ResetDayAnchor()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   g_dayAnchor      = StructToTime(dt);
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_haltedToday    = false;
  }

void UpdateDayAnchor()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   datetime today = StructToTime(dt);

   if(today != g_dayAnchor)
     {
      g_dayAnchor      = today;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_haltedToday    = false;
     }

   if(InpMaxDailyLossPct <= 0.0 || g_haltedToday || g_dayStartEquity <= 0.0)
      return;

   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct = (g_dayStartEquity - equity) / g_dayStartEquity * 100.0;
   if(lossPct >= InpMaxDailyLossPct)
     {
      g_haltedToday = true;
      PrintFormat("Daily loss limit hit (-%.2f%%). No new entries until the next trading day. "
                  "Open positions stay managed.", lossPct);
     }
  }
//+------------------------------------------------------------------+
