// NOTE: Tidak ada jaminan winrate 99%. Implementasi harus aman, transparan, dan mencatat semua metrik.
#property copyright "2024"
#property link      "https://example.com"
#property version   "1.00"
#property description "MQ5 Sniper XAUUSD — Target 5% Daily Compounding"
#property strict

#include <Trade/Trade.mqh>

//--- Input parameters
input double   StartCapital              = 100.0;  // Reference capital for backtests
input double   DailyTargetPercent        = 5.0;    // Daily compounding target percent
input double   MaxRiskPercentPerTrade    = 1.0;    // Maximum risk per trade
input double   MaxDailyLossPercent       = 10.0;   // Maximum daily loss percent
input int      MaxTradesPerDay           = 3;      // Maximum number of trades per day
input int      MaxSpreadPoints           = 50;     // Maximum spread (points)
input int      MaxSlippagePoints         = 200;    // Maximum slippage (points)
input ulong    MagicNumber               = 605050; // Unique magic number
input int      MinDistancePipsEntry      = 50;     // Minimum distance in points for limit orders
input bool     UseLimitOrders            = true;   // Enable sniper limit entries
input int      TradeStartHour            = 0;      // Trading start hour (server time)
input int      TradeEndHour              = 23;     // Trading end hour (server time)
input bool     AllowNewsFilter           = false;  // Placeholder toggle for news filter
input int      AccountLeverage           = 2000;   // Reference leverage
input double   MaxLot                    = 50.0;   // Broker maximum lot
input double   MinLot                    = 0.01;   // Broker minimum lot
input double   LotStep                   = 0.01;   // Broker lot step
input bool     EnablePartialClose        = false;  // Enable partial closing
input int      PartialClosePercent       = 50;     // Percent to close when partial close triggers
input bool     LogToFile                 = true;   // Write detailed logs to file
input double   PipSizePoints             = 10.0;   // Pip definition in points for gold
input double   BaseTPPips                = 200.0;  // Default TP in pips (points)
input double   ATRPeriod                 = 14;     // ATR period for volatility calculations
input double   ATRMultiplierSL           = 1.5;    // SL = ATR * multiplier
input double   RewardToRisk              = 2.0;    // Reward-to-risk ratio for TP
input ENUM_TIMEFRAMES EntryTimeframe     = PERIOD_M5;   // Entry timeframe
input ENUM_TIMEFRAMES ConfirmationTf     = PERIOD_H1;   // Confirmation timeframe
input int      FastEMA                   = 21;     // Fast EMA period
input int      SlowEMA                   = 55;     // Slow EMA period
input double   KillSwitchDrawdownPercent = 30.0;   // Disable EA if drawdown exceeds this percent of balance
input bool     EnableTrailingStop        = true;   // Enable ATR trailing stop
input double   TrailingATRMultiplier     = 1.0;    // ATR multiplier for trailing stop
input int      DailyResetHour            = 0;      // Hour to reset daily statistics
input bool     ManualKillSwitch          = false;  // Manual kill switch to pause trading

//--- Global variables
CTrade         trade;
int            g_dayTrades              = 0;
double         g_dayProfit              = 0.0;
double         g_dailyStartBalance      = 0.0;
datetime       g_lastResetTime          = 0;
bool           g_tradingDisabled        = false;
bool           g_killSwitchTriggered    = false;
double         g_highestBalance         = 0.0;
int            g_logHandle              = INVALID_HANDLE;
string         g_logFileName            = "MQ5SniperXAUUSD_log.csv";
double         g_brokerMinLot           = MinLot;
double         g_brokerMaxLot           = MaxLot;
double         g_brokerLotStep          = LotStep;
double         g_lastCalculatedLot      = 0.0;
bool           g_lastTargetAchievable   = true;
double         g_lastSLPoints           = 0.0;
double         g_lastTPPoints           = 0.0;
int            g_fastMAHandle           = INVALID_HANDLE;
int            g_slowMAHandle           = INVALID_HANDLE;
bool           g_newsWarningIssued      = false;
int            g_atrHandle              = INVALID_HANDLE;
bool           g_manualKillNotified     = false;

//--- Forward declarations
bool   InitializeLogger();
void   CloseLogger();
void   LogEvent(const string text);
void   ResetDailyStats();
void   CheckDailyReset();
bool   CheckSymbolRequirements();
bool   CheckTradingHours();
bool   CheckSpread();
void   UpdateDailyMetrics();
bool   KillSwitchCheck();
void   ManageOpenPositions();
bool   SignalDetected(bool &isBuy, double &entryPrice, double &stopLoss, double &takeProfit, bool &useLimit, double &lotSize);
double CalculateATR(ENUM_TIMEFRAMES tf, int period);
double CalculateLotSize(double tpPoints, double slPoints, bool &targetAchievable);
double NormalizeLotUp(double lot);
double NormalizeLotDown(double lot);
bool   SendTrade(const bool isBuy, const double entryPrice, const double sl, const double tp, const bool useLimit, const double lotSize);
void   PersistDailyState();
void   LoadDailyState();
string TodayKey();
void   RecordPerformanceMetrics();
void   ApplyTrailingStops();
void   HandlePartialClose();
bool   NewsFilterAllowsTrading();
datetime DateOfDay(datetime timeValue);

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!CheckSymbolRequirements())
      return(INIT_FAILED);

   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints(MaxSlippagePoints);

   g_fastMAHandle = iMA(_Symbol, ConfirmationTf, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_slowMAHandle = iMA(_Symbol, ConfirmationTf, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(g_fastMAHandle==INVALID_HANDLE || g_slowMAHandle==INVALID_HANDLE)
   {
      LogEvent("Failed to create EMA indicators.");
      return(INIT_FAILED);
   }

   g_atrHandle = iATR(_Symbol, EntryTimeframe, (int)MathMax(2, ATRPeriod));
   if(g_atrHandle==INVALID_HANDLE)
   {
      LogEvent("Failed to create ATR indicator.");
      return(INIT_FAILED);
   }

   LoadDailyState();
   if(g_dailyStartBalance <= 0.0)
   {
      g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_highestBalance    = g_dailyStartBalance;
   }
   else
   {
      LogEvent(StringFormat("State restored: trades=%d, profit=%.2f, disabled=%s, killSwitch=%s", g_dayTrades, g_dayProfit, g_tradingDisabled?"true":"false", g_killSwitchTriggered?"true":"false"));
   }

   g_lastResetTime = TimeCurrent();
   if(!InitializeLogger())
      Print("Logger initialization failed. Continuing without file logs.");

   LogEvent("EA initialized");

   EventSetTimer(60);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   LogEvent(StringFormat("EA deinitialized, reason=%d", reason));
   CloseLogger();
   EventKillTimer();
   if(g_fastMAHandle!=INVALID_HANDLE)
      IndicatorRelease(g_fastMAHandle);
   if(g_slowMAHandle!=INVALID_HANDLE)
      IndicatorRelease(g_slowMAHandle);
   if(g_atrHandle!=INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   PersistDailyState();
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   CheckDailyReset();
   UpdateDailyMetrics();
   RecordPerformanceMetrics();
   ManageOpenPositions();
   PersistDailyState();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   ManageOpenPositions();

   if(g_tradingDisabled || g_killSwitchTriggered)
      return;

   if(ManualKillSwitch)
   {
      if(!g_manualKillNotified)
      {
         LogEvent("Manual kill switch active. Trading halted.");
         g_manualKillNotified = true;
      }
      return;
   }
   else if(g_manualKillNotified)
   {
      LogEvent("Manual kill switch released. Trading resumed.");
      g_manualKillNotified = false;
   }

   if(!NewsFilterAllowsTrading())
      return;

   if(!CheckTradingHours())
      return;

   if(!CheckSpread())
      return;

   UpdateDailyMetrics();
   if(KillSwitchCheck())
      return;

   if(g_dayTrades >= MaxTradesPerDay)
   {
      LogEvent("Max trades per day reached");
      return;
   }

   bool isBuy=false;
   double entryPrice=0, sl=0, tp=0;
   bool useLimit=false;
   double lotSize=0.0;

   if(!SignalDetected(isBuy, entryPrice, sl, tp, useLimit, lotSize))
      return;

   if(SendTrade(isBuy, entryPrice, sl, tp, useLimit, lotSize))
   {
      g_dayTrades++;
      LogEvent(StringFormat("Trade placed: %s, entry=%.2f, sl=%.2f, tp=%.2f, lot=%.2f", isBuy?"BUY":"SELL", entryPrice, sl, tp, lotSize));
   }
}

//+------------------------------------------------------------------+
//| Trade transaction handler                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if((trans.type==TRADE_TRANSACTION_DEAL_ADD || trans.type==TRADE_TRANSACTION_DEAL_UPDATE) && trans.deal>0)
   {
      if(HistoryDealSelect(trans.deal))
      {
         long dealMagic = (long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
         if(dealMagic==(long)MagicNumber)
         {
            double dealProfit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
            LogEvent(StringFormat("Deal event. Type=%d, Deal=%I64d, profit=%.2f", trans.type, trans.deal, dealProfit));
         }
      }
   }

   if(trans.type==TRADE_TRANSACTION_DEAL_ADD || trans.type==TRADE_TRANSACTION_DEAL_UPDATE)
   {
      UpdateDailyMetrics();
   }
}

//+------------------------------------------------------------------+
//| Check symbol and broker requirements                             |
//+------------------------------------------------------------------+
bool CheckSymbolRequirements()
{
   string symbol = _Symbol;
   if(symbol!="XAUUSD")
   {
      Alert("EA designed for XAUUSD only. Current symbol: ", symbol);
      return(false);
   }

   double minLot   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double stepLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(minLot>0.0) g_brokerMinLot = MathMax(MinLot, minLot);
   if(maxLot>0.0) g_brokerMaxLot = MathMin(MaxLot, maxLot);
   if(stepLot>0.0) g_brokerLotStep = stepLot;

   if(g_brokerMinLot<=0) g_brokerMinLot = MinLot;
   if(g_brokerMaxLot<=0) g_brokerMaxLot = MaxLot;
   if(g_brokerLotStep<=0) g_brokerLotStep = LotStep;

   LogEvent(StringFormat("Broker limits applied. MinLot=%.2f, MaxLot=%.2f, Step=%.2f", g_brokerMinLot, g_brokerMaxLot, g_brokerLotStep));

   return(true);
}

//+------------------------------------------------------------------+
//| Logging helpers                                                  |
//+------------------------------------------------------------------+
bool InitializeLogger()
{
   if(!LogToFile)
      return(true);

   string header = "timestamp,event\n";
   int flags = FILE_WRITE|FILE_CSV|FILE_SHARE_WRITE|FILE_READ;
   g_logHandle = FileOpen(g_logFileName, flags);
   if(g_logHandle==INVALID_HANDLE)
   {
      Print("Failed to open log file: ", GetLastError());
      return(false);
   }

   if(FileSize(g_logHandle)==0)
   {
      FileWriteString(g_logHandle, header);
   }

   return(true);
}

void CloseLogger()
{
   if(g_logHandle!=INVALID_HANDLE)
   {
      FileClose(g_logHandle);
      g_logHandle = INVALID_HANDLE;
   }
}

void LogEvent(const string text)
{
   string timestamp = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   Print("[MQ5Sniper] ", text);
   if(LogToFile && g_logHandle!=INVALID_HANDLE)
   {
      FileSeek(g_logHandle, 0, SEEK_END);
      FileWrite(g_logHandle, timestamp, text);
   }
}

//+------------------------------------------------------------------+
//| Daily statistics management                                      |
//+------------------------------------------------------------------+
void ResetDailyStats()
{
   g_dayTrades         = 0;
   g_dayProfit         = 0.0;
   g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_highestBalance    = g_dailyStartBalance;
   g_tradingDisabled   = false;
   g_killSwitchTriggered = false;
   g_lastResetTime     = TimeCurrent();
   g_lastCalculatedLot = 0.0;
   g_lastTargetAchievable = true;
   g_lastSLPoints = 0.0;
   g_lastTPPoints = 0.0;
   g_manualKillNotified = false;
   LogEvent(StringFormat("Daily stats reset. StartBalance=%.2f, ReferenceCapital=%.2f", g_dailyStartBalance, StartCapital));
}

void CheckDailyReset()
{
   datetime currentTime = TimeCurrent();
   int currentHour      = TimeHour(currentTime);
   if(currentHour == DailyResetHour)
   {
      datetime today = DateOfDay(currentTime);
      datetime last  = DateOfDay(g_lastResetTime);
      if(today != last)
      {
         PersistDailyState();
         ResetDailyStats();
      }
   }
}

void UpdateDailyMetrics()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_highestBalance = MathMax(g_highestBalance, balance);
   g_dayProfit      = balance - g_dailyStartBalance;

   double dynamicTarget = balance * DailyTargetPercent / 100.0;
   if(g_dayProfit >= dynamicTarget && dynamicTarget>0 && !g_tradingDisabled)
   {
      g_tradingDisabled = true;
      LogEvent("Daily profit target reached. Trading paused until reset.");
   }

   if(g_dayProfit <= - (MaxDailyLossPercent/100.0) * g_dailyStartBalance && !g_tradingDisabled)
   {
      g_tradingDisabled = true;
      LogEvent("Daily max loss reached. Trading disabled for the day.");
   }
}

bool KillSwitchCheck()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double drawdown = (g_highestBalance - balance);
   if(g_highestBalance>0)
   {
      double ddPercent = (drawdown / g_highestBalance) * 100.0;
      if(ddPercent >= KillSwitchDrawdownPercent)
      {
         g_killSwitchTriggered = true;
         LogEvent(StringFormat("Kill switch triggered. Drawdown=%.2f%%", ddPercent));
         return(true);
      }
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Signal generation                                                |
//+------------------------------------------------------------------+
bool SignalDetected(bool &isBuy, double &entryPrice, double &stopLoss, double &takeProfit, bool &useLimit, double &lotSize)
{
   useLimit = UseLimitOrders;

   int barsNeeded = MathMax(5, int(ATRPeriod)+5);
   if(Bars(_Symbol, EntryTimeframe) < barsNeeded || Bars(_Symbol, ConfirmationTf) < barsNeeded)
      return(false);

   double fastEMA[3];
   double slowEMA[3];
   if(g_fastMAHandle==INVALID_HANDLE || g_slowMAHandle==INVALID_HANDLE)
      return(false);

   if(CopyBuffer(g_fastMAHandle, 0, 0, 3, fastEMA)<=0)
      return(false);
   if(CopyBuffer(g_slowMAHandle, 0, 0, 3, slowEMA)<=0)
      return(false);

   bool trendUp = fastEMA[0] > slowEMA[0];
   bool trendDown = fastEMA[0] < slowEMA[0];

   double open[3], close[3], high[3], low[3];
   if(CopyOpen(_Symbol, EntryTimeframe, 0, 3, open)<=0)
      return(false);
   if(CopyClose(_Symbol, EntryTimeframe, 0, 3, close)<=0)
      return(false);
   if(CopyHigh(_Symbol, EntryTimeframe, 0, 3, high)<=0)
      return(false);
   if(CopyLow(_Symbol, EntryTimeframe, 0, 3, low)<=0)
      return(false);

   double atrPoints = CalculateATR(EntryTimeframe, int(ATRPeriod));
   if(atrPoints <= 0)
      return(false);

   double slPoints = atrPoints * ATRMultiplierSL / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tpPoints = BaseTPPips;
   if(tpPoints <= 0)
      tpPoints = atrPoints * RewardToRisk * ATRMultiplierSL / SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   bool patternDetected = false;

   // Bullish engulfing
   if(close[1] < open[1] && close[0] > open[0] && close[0] > open[1] && open[0] <= close[1])
   {
      isBuy = true;
      patternDetected = trendUp;
   }
   // Bearish engulfing
   else if(close[1] > open[1] && close[0] < open[0] && close[0] < open[1] && open[0] >= close[1])
   {
      isBuy = false;
      patternDetected = trendDown;
   }

   // Pin bar detection
   double body = MathAbs(close[0]-open[0]);
   double candleRange = high[0]-low[0];
   if(body>0 && candleRange>0 && !patternDetected)
   {
      double upperWick = high[0] - MathMax(close[0], open[0]);
      double lowerWick = MathMin(close[0], open[0]) - low[0];
      if(upperWick>=2*body && lowerWick<=0.5*body && trendDown)
      {
         isBuy = false;
         patternDetected = true;
      }
      else if(lowerWick>=2*body && upperWick<=0.5*body && trendUp)
      {
         isBuy = true;
         patternDetected = true;
      }
   }

   if(!patternDetected)
      return(false);

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(isBuy)
   {
      entryPrice = useLimit ? MathMin(ask - MinDistancePipsEntry * point, ask) : ask;
      stopLoss   = entryPrice - slPoints * point;
      takeProfit = entryPrice + tpPoints * point;
   }
   else
   {
      entryPrice = useLimit ? MathMax(price + MinDistancePipsEntry * point, price) : price;
      stopLoss   = entryPrice + slPoints * point;
      takeProfit = entryPrice - tpPoints * point;
   }

   bool targetAchievable = true;
   lotSize = CalculateLotSize(tpPoints, slPoints, targetAchievable);
   if(lotSize < g_brokerMinLot)
   {
      LogEvent("Lot size below minimum. Signal ignored.");
      return(false);
   }

   if(!targetAchievable)
      LogEvent("Daily target not achievable with safe risk. Proceeding with reduced lot size.");

   g_lastCalculatedLot    = lotSize;
   g_lastTargetAchievable = targetAchievable;
   g_lastSLPoints         = slPoints;
   g_lastTPPoints         = tpPoints;

   // margin check
   double margin=0;
   ENUM_ORDER_TYPE orderType = ORDER_TYPE_BUY;
   if(useLimit)
      orderType = isBuy ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
   else
      orderType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   if(!OrderCalcMargin(orderType, _Symbol, lotSize, entryPrice, margin))
   {
      LogEvent("Failed to calculate margin.");
      return(false);
   }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double leverage = (double)AccountInfoInteger(ACCOUNT_LEVERAGE);
   if(leverage<=0)
      leverage = AccountLeverage;
   double marginBuffer = AccountInfoDouble(ACCOUNT_BALANCE) / leverage;

   if(margin > freeMargin)
   {
      LogEvent("Insufficient margin for trade.");
      return(false);
   }

   if(freeMargin - margin < marginBuffer)
   {
      LogEvent("Margin buffer too low after planned trade.");
      return(false);
   }

   return(true);
}

//+------------------------------------------------------------------+
//| ATR calculation                                                  |
//+------------------------------------------------------------------+
double CalculateATR(ENUM_TIMEFRAMES tf, int period)
{
   int requiredPeriod = (int)MathMax(2, period);
   if(tf!=EntryTimeframe || requiredPeriod!=(int)MathMax(2, ATRPeriod))
   {
      int handle = iATR(_Symbol, tf, requiredPeriod);
      if(handle==INVALID_HANDLE)
         return(0.0);
      double atrTemp[];
      if(CopyBuffer(handle, 0, 0, 1, atrTemp)<=0)
      {
         IndicatorRelease(handle);
         return(0.0);
      }
      IndicatorRelease(handle);
      return(atrTemp[0]);
   }

   if(g_atrHandle==INVALID_HANDLE)
      return(0.0);

   double atrArray[];
   if(CopyBuffer(g_atrHandle, 0, 0, 1, atrArray)<=0)
      return(0.0);

   return(atrArray[0]);
}

//+------------------------------------------------------------------+
//| Lot size calculation                                             |
//+------------------------------------------------------------------+
double CalculateLotSize(double tpPoints, double slPoints, bool &targetAchievable)
{
   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(point<=0 || tickValue<=0 || tickSize<=0)
      return(NormalizeLotUp(g_brokerMinLot));

   double pipValuePerLot = tickValue * (PipSizePoints / tickSize);
   double tpValuePerLot  = pipValuePerLot * (tpPoints / PipSizePoints);
   if(tpValuePerLot<=0)
      return(NormalizeLotUp(g_brokerMinLot));

   double dailyTarget = AccountInfoDouble(ACCOUNT_BALANCE) * DailyTargetPercent / 100.0;
   double lotNeeded   = dailyTarget / tpValuePerLot;

   double lot = NormalizeLotUp(lotNeeded);
   lot = MathMax(lot, g_brokerMinLot);
   lot = MathMin(lot, g_brokerMaxLot);

   // Risk constraint
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double maxRiskValue = balance * MaxRiskPercentPerTrade / 100.0;
   double slValuePerLot = pipValuePerLot * (slPoints / PipSizePoints);
   if(slValuePerLot<=0)
      slValuePerLot = tickValue * (slPoints * point / tickSize);

   if(slValuePerLot>0)
   {
      double lotByRisk = maxRiskValue / slValuePerLot;
      lotByRisk = NormalizeLotDown(lotByRisk);
      if(lotByRisk < g_brokerMinLot)
      {
         targetAchievable = false;
         return(0.0);
      }

      if(lot > lotByRisk)
      {
         lot = lotByRisk;
         targetAchievable = false;
      }
   }

   lot = MathMax(lot, g_brokerMinLot);
   lot = MathMin(lot, g_brokerMaxLot);
   return(lot);
}

//+------------------------------------------------------------------+
//| Normalize lot sizes                                              |
//+------------------------------------------------------------------+
double NormalizeLotUp(double lot)
{
   if(g_brokerLotStep>0)
      lot = MathCeil(lot / g_brokerLotStep) * g_brokerLotStep;

   int digits = 2;
   if(g_brokerLotStep>0)
      digits = (int)MathRound(MathLog10(1.0/g_brokerLotStep));

   return(NormalizeDouble(lot, MathMax(1, digits)));
}

double NormalizeLotDown(double lot)
{
   if(g_brokerLotStep>0)
      lot = MathFloor(lot / g_brokerLotStep) * g_brokerLotStep;

   int digits = 2;
   if(g_brokerLotStep>0)
      digits = (int)MathRound(MathLog10(1.0/g_brokerLotStep));

   return(NormalizeDouble(lot, MathMax(1, digits)));
}

//+------------------------------------------------------------------+
//| Trade execution                                                  |
//+------------------------------------------------------------------+
bool SendTrade(const bool isBuy, const double entryPrice, const double sl, const double tp, const bool useLimit, const double lotSize)
{
   double lot = lotSize;
   if(lot <= 0.0)
   {
      LogEvent("Invalid lot size for trade.");
      return(false);
   }

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action   = TRADE_ACTION_DEAL;
   request.symbol   = _Symbol;
   request.magic    = MagicNumber;
   request.volume   = lot;
   request.deviation= MaxSlippagePoints;
   request.type_filling = ORDER_FILLING_FOK;
   request.type_time    = ORDER_TIME_GTC;

   if(useLimit)
   {
      request.action = TRADE_ACTION_PENDING;
      request.type_time = ORDER_TIME_GTC;
      request.volume = lot;
      if(isBuy)
      {
         request.type  = ORDER_TYPE_BUY_LIMIT;
         request.price = entryPrice;
      }
      else
      {
         request.type  = ORDER_TYPE_SELL_LIMIT;
         request.price = entryPrice;
      }
   }
   else
   {
      if(isBuy)
      {
         request.type  = ORDER_TYPE_BUY;
         request.price = entryPrice;
      }
      else
      {
         request.type  = ORDER_TYPE_SELL;
         request.price = entryPrice;
      }
   }

   request.price = NormalizeDouble(request.price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   request.sl = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   request.tp = NormalizeDouble(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

   if(!OrderSend(request, result))
   {
      LogEvent(StringFormat("OrderSend failed. Error=%d", GetLastError()));
      return(false);
   }

   if(result.retcode!=10009 && result.retcode!=10008)
   {
      LogEvent(StringFormat("OrderSend retcode=%d", result.retcode));
      return(false);
   }

   return(true);
}

//+------------------------------------------------------------------+
//| Utility functions                                                |
//+------------------------------------------------------------------+
bool CheckTradingHours()
{
   int currentHour = TimeHour(TimeCurrent());
   if(currentHour < TradeStartHour || currentHour > TradeEndHour)
   {
      LogEvent("Outside trading hours");
      return(false);
   }
   return(true);
}

bool CheckSpread()
{
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(spread > MaxSpreadPoints)
   {
      LogEvent(StringFormat("Spread too high: %.1f points", spread));
      return(false);
   }
   return(true);
}

void ManageOpenPositions()
{
   ApplyTrailingStops();
   HandlePartialClose();
}

void ApplyTrailingStops()
{
   if(!EnableTrailingStop)
      return;

   double atr = CalculateATR(EntryTimeframe, int(ATRPeriod));
   if(atr<=0)
      return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double trailDistance = atr * TrailingATRMultiplier;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)MagicNumber)
         continue;
      string symbol = PositionGetString(POSITION_SYMBOL);
      if(symbol!=_Symbol)
         continue;

      double priceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
      double sl = PositionGetDouble(POSITION_SL);
      long type = PositionGetInteger(POSITION_TYPE);

      if(type==POSITION_TYPE_BUY)
      {
         double newSL = currentPrice - trailDistance;
         if(newSL > sl + point)
         {
            if(trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP)))
               LogEvent(StringFormat("Trailing stop adjusted (BUY). Ticket=%I64d", ticket));
            else
               LogEvent(StringFormat("Trailing stop failed (BUY). Ticket=%I64d, error=%d", ticket, GetLastError()));
         }
      }
      else if(type==POSITION_TYPE_SELL)
      {
         double newSL = currentPrice + trailDistance;
         if(newSL < sl - point || sl==0.0)
         {
            if(trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP)))
               LogEvent(StringFormat("Trailing stop adjusted (SELL). Ticket=%I64d", ticket));
            else
               LogEvent(StringFormat("Trailing stop failed (SELL). Ticket=%I64d, error=%d", ticket, GetLastError()));
         }
      }
   }
}

void HandlePartialClose()
{
   if(!EnablePartialClose)
      return;
   if(PartialClosePercent<=0 || PartialClosePercent>=100)
      return;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)MagicNumber)
         continue;
      string symbol = PositionGetString(POSITION_SYMBOL);
      if(symbol!=_Symbol)
         continue;

      double volume = PositionGetDouble(POSITION_VOLUME);
      double tp = PositionGetDouble(POSITION_TP);
      double price = PositionGetDouble(POSITION_PRICE_CURRENT);
      long type = PositionGetInteger(POSITION_TYPE);

      if(tp==0.0)
         continue;

      bool tpReached = (type==POSITION_TYPE_BUY && price >= tp) || (type==POSITION_TYPE_SELL && price <= tp);
      if(tpReached)
      {
         double closeVolume = NormalizeLotDown(volume * PartialClosePercent / 100.0);
         if(closeVolume >= g_brokerMinLot && closeVolume < volume)
         {
            if(trade.PositionClosePartial(ticket, closeVolume))
               LogEvent(StringFormat("Partial close executed. Ticket=%I64d, volume=%.2f", ticket, closeVolume));
            else
               LogEvent(StringFormat("Partial close failed. Ticket=%I64d, error=%d", ticket, GetLastError()));
         }
      }
   }
}

bool NewsFilterAllowsTrading()
{
   if(!AllowNewsFilter)
      return(true);

   if(!g_newsWarningIssued)
   {
      LogEvent("AllowNewsFilter enabled. Please integrate broker/calendar API for actual filtering.");
      g_newsWarningIssued = true;
   }

   // Placeholder always allows trading but informs user.
   return(true);
}

//+------------------------------------------------------------------+
//| Persistence                                                      |
//+------------------------------------------------------------------+
string TodayKey()
{
   datetime currentTime = TimeCurrent();
   string dateStr = TimeToString(currentTime, TIME_DATE);
   StringReplace(dateStr, ".", "_");
   return(StringFormat("MQ5Sniper_%I64d_%s", AccountInfoInteger(ACCOUNT_LOGIN), dateStr));
}

void PersistDailyState()
{
   string keyBase = TodayKey();
   GlobalVariableSet(keyBase+"_trades", g_dayTrades);
   GlobalVariableSet(keyBase+"_profit", g_dayProfit);
   GlobalVariableSet(keyBase+"_start", g_dailyStartBalance);
   GlobalVariableSet(keyBase+"_high", g_highestBalance);
   GlobalVariableSet(keyBase+"_disabled", g_tradingDisabled ? 1.0 : 0.0);
   GlobalVariableSet(keyBase+"_killswitch", g_killSwitchTriggered ? 1.0 : 0.0);
}

void LoadDailyState()
{
   string keyBase = TodayKey();
   if(GlobalVariableCheck(keyBase+"_start"))
      g_dailyStartBalance = GlobalVariableGet(keyBase+"_start");
   if(GlobalVariableCheck(keyBase+"_profit"))
      g_dayProfit = GlobalVariableGet(keyBase+"_profit");
   if(GlobalVariableCheck(keyBase+"_trades"))
      g_dayTrades = (int)GlobalVariableGet(keyBase+"_trades");
   if(GlobalVariableCheck(keyBase+"_high"))
      g_highestBalance = GlobalVariableGet(keyBase+"_high");
   if(GlobalVariableCheck(keyBase+"_disabled"))
      g_tradingDisabled = (GlobalVariableGet(keyBase+"_disabled") > 0.5);
   if(GlobalVariableCheck(keyBase+"_killswitch"))
      g_killSwitchTriggered = (GlobalVariableGet(keyBase+"_killswitch") > 0.5);
}

//+------------------------------------------------------------------+
//| Performance metrics                                              |
//+------------------------------------------------------------------+
void RecordPerformanceMetrics()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double profit  = AccountInfoDouble(ACCOUNT_PROFIT);
   double dayROI  = g_dailyStartBalance==0.0 ? 0.0 : (g_dayProfit / g_dailyStartBalance) * 100.0;

   LogEvent(StringFormat("Performance: Balance=%.2f, Equity=%.2f, Profit=%.2f, DayROI=%.2f%%, LastLot=%.2f, TargetSafe=%s, SLpts=%.1f, TPpts=%.1f", balance, equity, profit, dayROI, g_lastCalculatedLot, g_lastTargetAchievable?"true":"false", g_lastSLPoints, g_lastTPPoints));
}

//+------------------------------------------------------------------+
//| Utility                                                          |
//+------------------------------------------------------------------+
datetime DateOfDay(datetime timeValue)
{
   MqlDateTime dt;
   TimeToStruct(timeValue, dt);
   dt.hour = dt.min = dt.sec = 0;
   return(StructToTime(dt));
}

//+------------------------------------------------------------------+
//| Backtest notes                                                   |
//+------------------------------------------------------------------+
/*
Backtest notes:
- Recommended symbol: XAUUSD, timeframe M5 or M1 for entry.
- Optimize parameters: DailyTargetPercent, MaxRiskPercentPerTrade, ATRMultiplierSL, RewardToRisk,
  FastEMA, SlowEMA, BaseTPPips, MinDistancePipsEntry, TrailingATRMultiplier.
- Use "Every tick" modeling quality for sniper entry evaluation.
- Consider enabling news filter manually by pausing EA during high-impact events.
- Review Files/"MQ5SniperXAUUSD_log.csv" for trade logs and performance metrics.
*/

//+------------------------------------------------------------------+
//| End of file                                                      |
//+------------------------------------------------------------------+
