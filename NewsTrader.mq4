//+------------------------------------------------------------------+
//|                                                   NewsTrader.mq4 |
//|                                  Copyright © 2024, EarnForex.com |
//|                                       https://www.earnforex.com/ |
//+------------------------------------------------------------------+
#property copyright "Copyright © 2024, EarnForex"
#property link      "https://www.earnforex.com/metatrader-expert-advisors/News-Trader/"
#property version   "1.12"
#property strict

#property description "Opens a buy/sell trade (random, chosen direction, or both directions) seconds before news release."
#property description "Sets SL and TP. Keeps updating them until the very release."
#property description "Can set use trailing stop and breakeven."
#property description "ATR-based stop-loss option is also available."
#property description "Closes trade after one hour."

enum dir_enum
{
    Buy,
    Sell,
    Both,
    Random
};

enum trailing_enum
{
    None,
    Breakeven,
    Normal, // Normal trailing stop
    NormalPlusBE // Normal trailing stop + Breakeven
};

input group "Trading"
input datetime NewsTime = -1; // News date/time (Server)
input int StopLoss = 15; // Stop-loss in points
input int TakeProfit = 75; // Take-profit in points
input dir_enum Direction = Both; // Direction of the trade to open
input trailing_enum TrailingStop = None; // Trailing stop type
input int BEOnProfit = 0; // Profit to trigger breakeven, points
input int BEExtraProfit = 0; // Extra profit for breakeven, points
input int TSOnProfit = 0; // Profit to start trailing stop, points
input bool PreAdjustSLTP = false; // Preadjust SL/TP until news is out
input int SecondsBefore = 18; // Seconds before the news to open a trade
input int CloseAfterSeconds = 3600; // Close trade X seconds after the news, 0 - turn the feature off
input bool SpreadFuse = true; // SpreadFuse - prevent trading if spread >= stop-loss
input group "ATR"
input bool UseATR = false; // Use ATR-based stop-loss and take-profit levels
input int ATR_Period = 14; // ATR Period
input double ATR_Multiplier_SL = 1; // ATR multiplier for SL
input double ATR_Multiplier_TP = 5; // ATR multiplier for TP
input group "Money management"
input double Lots = 0.01;
input bool MM  = true; // Money Management, if true - position sizing based on stop-loss
input double Risk = 1; // Risk - Risk tolerance in percentage points
input double FixedBalance = 0; // FixedBalance: If > 0, trade size calc. uses it as balance
input double MoneyRisk = 0; // MoneyRisk: Risk tolerance in account currency
input bool UseMoneyInsteadOfPercentage = false; // Use money risk instead of percentage
input bool UseEquityInsteadOfBalance = false; // Use equity instead of balance
input group "Timer"
input bool ShowTimer = true; // Show timer before and after news
input int FontSize = 18;
input string Font = "Arial";
input color FontColor = clrRed;
input ENUM_BASE_CORNER Corner = CORNER_LEFT_UPPER;
input int X_Distance = 10; // X-axis distance from the chart corner
input int Y_Distance = 130; // Y-axis distance from the chart corner
input group "Miscellaneous"
input int Slippage = 3;
input int Magic = 794823491;
input string Commentary = "NewsTrader"; // Comment - trade description (e.g. "US CPI", "EU GDP", etc.)
input bool IgnoreECNMode = true; // IgnoreECNMode: Always attach SL/TP immediately

// Global variables:
bool HaveLongPosition, HaveShortPosition;
bool ECN_Mode;

int news_time;
bool CanTrade = false;
bool Terminal_Trade_Allowed = true;

double SL, TP;

// For tick value adjustment:
string ProfitCurrency = "", account_currency = "", BaseCurrency = "", ReferenceSymbol = NULL, AdditionalReferenceSymbol = NULL;
bool ReferenceSymbolMode, AdditionalReferenceSymbolMode;
int ProfitCalcMode;

void OnInit()
{
    news_time = (int)NewsTime;
    double min_lot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
    if ((Lots < min_lot) && (!MM))
    {
        double lot_step = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
        int LotStep_digits = CountDecimalPlaces(lot_step);
        Print("Minimum lot: ", DoubleToString(min_lot, LotStep_digits), ", lot step: ", DoubleToString(lot_step, LotStep_digits), ".");
        Alert("Lots should be not less than: ", DoubleToString(min_lot, LotStep_digits), ".");
    }
    else CanTrade = true;

    if (ShowTimer)
    {
        ObjectCreate(ChartID(), "NewsTraderTimer", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(ChartID(), "NewsTraderTimer", OBJPROP_CORNER, Corner);
        ObjectSetInteger(ChartID(), "NewsTraderTimer", OBJPROP_XDISTANCE, X_Distance);
        ObjectSetInteger(ChartID(), "NewsTraderTimer", OBJPROP_YDISTANCE, Y_Distance);
        ObjectSetInteger(ChartID(), "NewsTraderTimer", OBJPROP_SELECTABLE, true);
        EventSetMillisecondTimer(100); // For smooth updates.
    }

    // If UseATR = false, these values will be used. Otherwise, ATR values will be calculated later.
    SL = StopLoss;
    TP = TakeProfit;
    
    if (BEExtraProfit > BEOnProfit) Print("Extra profit for breakeven shouldn't be greater than the profit to trigger breakeven parameter. Please check your input parameters.");
}

//+------------------------------------------------------------------+
//| Deletes graphical object if needed.                              |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    ObjectDelete(ChartID(), "NewsTraderTimer");
}

//+------------------------------------------------------------------+
//| Updates text about time left to news or passed after news.       |
//+------------------------------------------------------------------+
void OnTimer()
{
    DoTrading();
    string text;
    int difference = (int)TimeCurrent() - news_time;
    if (difference <= 0) text = "Time to news: " + TimeDistance(-difference);
    else text = "Time after news: " + TimeDistance(difference) + ".";
    ObjectSetString(ChartID(), "NewsTraderTimer", OBJPROP_TEXT, text);
    ObjectSetString(ChartID(), "NewsTraderTimer", OBJPROP_FONT, Font);
    ObjectSetInteger(ChartID(), "NewsTraderTimer", OBJPROP_FONTSIZE, FontSize);
    ObjectSetInteger(ChartID(), "NewsTraderTimer", OBJPROP_COLOR, FontColor);
}

//+------------------------------------------------------------------+
//| Format time distance from the number of seconds to normal string |
//| of years, days, hours, minutes, and seconds.                     |
//| t - number of seconds                                            |
//| Returns: formatted string.                                       |
//+------------------------------------------------------------------+
string TimeDistance(int t)
{
    if (t == 0) return "0 seconds";
    string s = "";
    int y = 0;
    int d = 0;
    int h = 0;
    int m = 0;

    y = t / 31536000;
    t -= y * 31536000;

    d = t / 86400;
    t -= d * 86400;

    h = t / 3600;
    t -= h * 3600;

    m = t / 60;
    t -= m * 60;

    if (y) s += IntegerToString(y) + " year";
    if (y > 1) s += "s";

    if (d) s += " " + IntegerToString(d) + " day";
    if (d > 1) s += "s";

    if (h) s += " " + IntegerToString(h) + " hour";
    if (h > 1) s += "s";

    if (m) s += " " + IntegerToString(m) + " minute";
    if (m > 1) s += "s";

    if (t) s += " " + IntegerToString(t) + " second";
    if (t > 1) s += "s";

    return StringTrimLeft(s);
}

void OnTick()
{
    DoTrading();
}

//+------------------------------------------------------------------+
//| Main execution procedure.                                        |
//+------------------------------------------------------------------+
void DoTrading()
{
    if ((TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == false) || (!CanTrade))
    {
        if ((TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == false) && (Terminal_Trade_Allowed == true))
        {
            Print("Trading not allowed.");
            Terminal_Trade_Allowed = false;
        }
        else if ((TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == true) && (Terminal_Trade_Allowed == false))
        {
            Print("Trading allowed.");
            Terminal_Trade_Allowed = true;
        }
        return;
    }

    ENUM_SYMBOL_TRADE_EXECUTION Execution_Mode = (ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(Symbol(), SYMBOL_TRADE_EXEMODE);
    if (Execution_Mode == SYMBOL_TRADE_EXECUTION_MARKET) ECN_Mode = true;
    else ECN_Mode = false;
    if (IgnoreECNMode) ECN_Mode = false;

    // Do nothing if it is too early.
    int time = (int)TimeCurrent();
    if (time < news_time - SecondsBefore) return;

    if (UseATR)
    {
        // Getting the ATR values
        double ATR = iATR(NULL, 0, ATR_Period, 0);
        SL = ATR * ATR_Multiplier_SL;
        if (SL <= (SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL) + SymbolInfoInteger(Symbol(), SYMBOL_SPREAD)) * Point) SL = (SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL) + SymbolInfoInteger(Symbol(), SYMBOL_SPREAD)) * Point;
        TP = ATR * ATR_Multiplier_TP;
        if (TP <= (SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL) + SymbolInfoInteger(Symbol(), SYMBOL_SPREAD)) * Point) TP = (SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL) + SymbolInfoInteger(Symbol(), SYMBOL_SPREAD)) * Point;
        SL /= Point;
        TP /= Point;
    }

    // Check what position is currently open.
    GetPositionStates();

    // Adjust SL and TP of the current position.
    if ((HaveLongPosition) || (HaveShortPosition)) ControlPosition();
    else
    {
        // Time to news is less or equal to SecondsBefore but is not negative.
        if ((news_time - time <= SecondsBefore) && (news_time > time))
        {
            // Prevent position opening when spreads are too wide (bigger than StopLoss input).
            int spread = (int)MarketInfo(Symbol(), MODE_SPREAD);
            if ((SpreadFuse) && (spread >= StopLoss))
            {
                Print(Symbol(), ": Spread fuse prevents positions from opening. Current spread: ", spread, " points.");
                return;
            }
            if (Direction == Buy) fBuy();
            else if (Direction == Sell) fSell();
            else if (Direction == Both)
            {
                fBuy();
                fSell();
            }
            else if (Direction == Random)
            {
                MathSrand((uint)TimeCurrent());
                if (MathRand() % 2 == 1) fBuy();
                else fSell();
            }
            if (ECN_Mode) ControlPosition();
        }
    }
}

//+------------------------------------------------------------------+
//| Check what positions are currently open.                         |
//+------------------------------------------------------------------+
void GetPositionStates()
{
    HaveLongPosition = false;
    HaveShortPosition = false;
    int total = OrdersTotal();
    for (int cnt = 0; cnt < total; cnt++)
    {
        if (OrderSelect(cnt, SELECT_BY_POS, MODE_TRADES) == false) continue;
        if (OrderMagicNumber() != Magic) continue;
        if (OrderSymbol() != Symbol()) continue;

        if (OrderType() == OP_BUY) HaveLongPosition = true;
        else if (OrderType() == OP_SELL) HaveShortPosition = true;
    }
}

//+------------------------------------------------------------------+
//| Add SL/TP, adjust SL/TP, set breakeven, close trade.             |
//+------------------------------------------------------------------+
void ControlPosition()
{
    int total = OrdersTotal();
    for (int cnt = total - 1; cnt >= 0; cnt--)
    {
        if (OrderSelect(cnt, SELECT_BY_POS, MODE_TRADES) == false) continue;
        if (OrderMagicNumber() != Magic) continue;
        if (OrderSymbol() != Symbol()) continue;

        if ((OrderType() == OP_BUY) || (OrderType() == OP_SELL))
        {
            int time = (int)TimeCurrent();

            double new_sl, new_tp;
            if (SL < MarketInfo(Symbol(), MODE_STOPLEVEL) + MarketInfo(Symbol(), MODE_SPREAD)) SL = MarketInfo(Symbol(), MODE_STOPLEVEL) + MarketInfo(Symbol(), MODE_SPREAD);
            if (TP < MarketInfo(Symbol(), MODE_STOPLEVEL) + MarketInfo(Symbol(), MODE_SPREAD)) TP = MarketInfo(Symbol(), MODE_STOPLEVEL) + MarketInfo(Symbol(), MODE_SPREAD);

            if (OrderType() == OP_BUY)
            {
                RefreshRates();
                new_sl = NormalizeDouble(Ask - SL * Point, Digits);
                new_tp = NormalizeDouble(Ask + TP * Point, Digits);
            }
            else if (OrderType() == OP_SELL)
            {
                RefreshRates();
                new_sl = NormalizeDouble(Bid + SL * Point, Digits);
                new_tp = NormalizeDouble(Bid - TP * Point, Digits);
            }
            // Need to adjust or add SL/TP.
            if (time < news_time)
            {
                // Adjust only if parameter is set or if in ECN mode and need to assign SL/TP first time.
                if ((((new_sl != NormalizeDouble(OrderStopLoss(), Digits)) || (new_tp != NormalizeDouble(OrderTakeProfit(), Digits))) && (PreAdjustSLTP)) ||
                        (((OrderStopLoss() == 0) || (OrderTakeProfit() == 0)) && (ECN_Mode)))
                {
                    Print("Adjusting SL: ", DoubleToString(new_sl, _Digits), " and TP: ", DoubleToString(new_tp, _Digits), ".");
                    for (int i = 0; i < 10; i++)
                    {
                        bool result = OrderModify(OrderTicket(), OrderOpenPrice(), new_sl, new_tp, 0);
                        if (result) return;
                        else Print("Error modifying the order: ", GetLastError());
                    }
                }
            }
            // Check for breakeven or trade time out. Plus, sometimes, in ECN mode, it is necessary to check if SL/TP was set even after the news.
            else
            {
                RefreshRates();
                // Adjust only if in ECN mode and need to assign SL/TP first time.
                if (((OrderStopLoss() == 0) || (OrderTakeProfit() == 0)) && (ECN_Mode))
                {
                    Print("Adjusting SL: ", DoubleToString(new_sl, _Digits), " and TP: ", DoubleToString(new_tp, _Digits), ".");
                    for (int i = 0; i < 10; i++)
                    {
                        bool result = OrderModify(OrderTicket(), OrderOpenPrice(), new_sl, new_tp, 0);
                        if (result) return;
                        else Print("Error modifying the order: ", GetLastError());
                    }
                }
                // Breakeven.
                if (((TrailingStop == Breakeven) || (TrailingStop == NormalPlusBE)) && ((((OrderType() == OP_BUY) && (Bid - OrderOpenPrice() >= BEOnProfit * _Point)) || ((OrderType() == OP_SELL) && (OrderOpenPrice() - Ask >= BEOnProfit * _Point)))))
                {
                    new_sl = NormalizeDouble(OrderOpenPrice(), _Digits);
                    if (BEExtraProfit > 0) // Breakeven extra profit?
                    {
                        if (OrderType() == OP_BUY) new_sl += BEExtraProfit * _Point; // For buys.
                        else new_sl -= BEExtraProfit * _Point; // For sells.
                        new_sl = NormalizeDouble(new_sl, _Digits);
                    }
                    if (((OrderType() == OP_BUY) && (new_sl > OrderStopLoss())) || ((OrderType() == OP_SELL) && ((new_sl < OrderStopLoss()) || (OrderStopLoss() == 0)))) // Avoid moving SL to BE if this SL is already there or in a better position.
                    {
                        Print("Moving SL to breakeven: ", new_sl, ".");
                        for (int i = 0; i < 10; i++)
                        {
                            bool result = OrderModify(OrderTicket(), OrderOpenPrice(), new_sl, OrderTakeProfit(), 0);
                            if (result) break;
                            else Print("Position modification error: ", GetLastError());
                        }
                    }
                }
                // Trailing stop.
                if (((TrailingStop == Normal) || (TrailingStop == NormalPlusBE)) && ((TSOnProfit == 0) || ((OrderType() == OP_BUY) && (Bid - OrderOpenPrice() >= TSOnProfit * _Point)) || ((OrderType() == OP_SELL) && (OrderOpenPrice() - Ask >= TSOnProfit * _Point))))
                {
                    if (OrderType() == OP_BUY) new_sl = NormalizeDouble(Bid - SL * _Point, _Digits);
                    else if (OrderType() == OP_SELL) new_sl = NormalizeDouble(Ask + SL * _Point, _Digits);
                    if (((OrderType() == OP_BUY) && (new_sl > OrderStopLoss())) || ((OrderType() == OP_SELL) && ((new_sl < OrderStopLoss()) || (OrderStopLoss() == 0)))) // Avoid moving the SL if this SL is already in a better position.
                    {
                        Print("Moving trailing SL to ", new_sl, ".");
                        for (int i = 0; i < 10; i++)
                        {
                            bool result = OrderModify(OrderTicket(), OrderOpenPrice(), new_sl, OrderTakeProfit(), 0);
                            if (result) break;
                            else Print("Position modification error: ", GetLastError());
                        }
                    }
                }
                if (CloseAfterSeconds > 0)
                {
                    if (time - news_time >= CloseAfterSeconds)
                    {
                        Print("Closing trade by time out.");
                        double price;
                        RefreshRates();
                        if (OrderType() == OP_BUY) price = Bid;
                        else if (OrderType() == OP_SELL) price = Ask;
                        if (!OrderClose(OrderTicket(), OrderLots(), price, Slippage, clrBlue))
                        {
                            Print("OrderClose() failed: ", GetLastError());
                        }
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Generic buy.                                                     |
//+------------------------------------------------------------------+
void fBuy()
{
    Print("Opening Buy.");
    for (int i = 0; i < 10; i++)
    {
        double new_sl = 0, new_tp = 0;
        double lots = LotsOptimized(OP_BUY);
        RefreshRates();
        // Bid and Ask are swapped to preserve the probabilities and decrease/increase profit/loss size.
        if (!ECN_Mode)
        {
            new_sl = NormalizeDouble(Ask - SL * Point, Digits);
            new_tp = NormalizeDouble(Ask + TP * Point, Digits);
        }
        int result = OrderSend(Symbol(), OP_BUY, lots, Ask, Slippage, new_sl, new_tp, Commentary, Magic, 0, clrBlue);
        Sleep(1000);
        if (result == -1)
        {
            int e = GetLastError();
            Print("OrderSend Error: ", e, ".");
        }
        else return;
    }
}

//+------------------------------------------------------------------+
//| Generic sell.                                                    |
//+------------------------------------------------------------------+
void fSell()
{
    Print("Opening Sell.");
    for (int i = 0; i < 10; i++)
    {
        double new_sl = 0, new_tp = 0;
        double lots = LotsOptimized(OP_SELL);
        RefreshRates();
        // Bid and Ask are swapped to preserve the probabilities and decrease/increase profit/loss size.
        if (!ECN_Mode)
        {
            new_sl = NormalizeDouble(Bid + SL * Point, Digits);
            new_tp = NormalizeDouble(Bid - TP * Point, Digits);
        }
        int result = OrderSend(Symbol(), OP_SELL, lots, Bid, Slippage, new_sl, new_tp, Commentary, Magic, 0, clrRed);
        Sleep(1000);
        if (result == -1)
        {
            int e = GetLastError();
            Print("OrderSend Error: ", e, ".");
        }
        else return;
    }
}

//+------------------------------------------------------------------+
//| Calculate position size depending on money management parameters.|
//+------------------------------------------------------------------+
double LotsOptimized(int dir)
{
    if (!MM) return Lots;

    double Size, RiskMoney, PositionSize = 0, UnitCost;
    ProfitCurrency = SymbolInfoString(Symbol(), SYMBOL_CURRENCY_PROFIT);
    BaseCurrency = SymbolInfoString(Symbol(), SYMBOL_CURRENCY_BASE);
    ProfitCalcMode = (int)MarketInfo(Symbol(), MODE_PROFITCALCMODE);
    account_currency = AccountCurrency();
    // A rough patch for cases when account currency is set as RUR instead of RUB.
    if (account_currency == "RUR") account_currency = "RUB";
    if (ProfitCurrency == "RUR") ProfitCurrency = "RUB";
    if (BaseCurrency == "RUR") BaseCurrency = "RUB";
    double LotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
    int LotStep_digits = CountDecimalPlaces(LotStep);

    if (AccountCurrency() == "") return 0;

    if (FixedBalance > 0)
    {
        Size = FixedBalance;
    }
    else if (UseEquityInsteadOfBalance)
    {
        Size = AccountEquity();
    }
    else
    {
        Size = AccountBalance();
    }

    if (!UseMoneyInsteadOfPercentage) RiskMoney = Size * Risk / 100;
    else RiskMoney = MoneyRisk;

    // If Symbol is CFD.
    if (ProfitCalcMode == 1)
        UnitCost = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE) * SymbolInfoDouble(Symbol(), SYMBOL_TRADE_CONTRACT_SIZE); // Apparently, it is more accurate than taking TICKVALUE directly in some cases.
    else UnitCost = MarketInfo(Symbol(), MODE_TICKVALUE); // Futures or Forex.

    if (ProfitCalcMode != 0)  // Non-Forex might need to be adjusted.
    {
        // If profit currency is different from account currency.
        if (ProfitCurrency != account_currency)
        {
            double CCC = CalculateAdjustment(); // Valid only for loss calculation.
            // Adjust the unit cost.
            UnitCost *= CCC;
        }
    }

    // If account currency == pair's base currency, adjust UnitCost to future rate (SL). Works only for Forex pairs.
    if ((account_currency == BaseCurrency) && (ProfitCalcMode == 0))
    {
        double current_rate = 1, future_rate = 1;
        RefreshRates();
        if (dir == OP_BUY)
        {
            current_rate = Ask;
            future_rate = current_rate - SL * _Point;
        }
        else if (dir == OP_SELL)
        {
            current_rate = Bid;
            future_rate = current_rate + SL * _Point;
        }
        if (future_rate == 0) future_rate = _Point; // Zero divide prevention.
        UnitCost *= (current_rate / future_rate);
    }

    double TickSize = MarketInfo(Symbol(), MODE_TICKSIZE);

    if ((SL != 0) && (UnitCost != 0) && (TickSize != 0)) PositionSize = NormalizeDouble(RiskMoney / (SL * _Point * UnitCost / TickSize), LotStep_digits);

    if (PositionSize < MarketInfo(Symbol(), MODE_MINLOT))
    {
        Print("Calculated position size (" + DoubleToString(PositionSize, 2) + ") is less than minimum position size (" + DoubleToString(MarketInfo(Symbol(), MODE_MINLOT), 2) + "). Setting position size to minimum.");
        PositionSize = MarketInfo(Symbol(), MODE_MINLOT);
    }
    else if (PositionSize > MarketInfo(Symbol(), MODE_MAXLOT))
    {
        Print("Calculated position size (" + DoubleToString(PositionSize, 2) + ") is greater than maximum position size (" + DoubleToString(MarketInfo(Symbol(), MODE_MAXLOT), 2) + "). Setting position size to maximum.");
        PositionSize = MarketInfo(Symbol(), MODE_MAXLOT);
    }

    double steps = PositionSize / LotStep;
    if (MathFloor(steps) < steps)
    {
        Print("Calculated position size (" + DoubleToString(PositionSize, 2) + ") uses uneven step size. Allowed step size = " + DoubleToString(MarketInfo(Symbol(), MODE_LOTSTEP), 2) + ". Setting position size to " + DoubleToString(MathFloor(steps) * LotStep, 2) + ".");
        PositionSize = MathFloor(steps) * LotStep;
    }

    return PositionSize;
}

//+-----------------------------------------------------------------------------------+
//| Calculates necessary adjustments for cases when ProfitCurrency != AccountCurrency.|
//+-----------------------------------------------------------------------------------+
#define FOREX_SYMBOLS_ONLY 0
#define NONFOREX_SYMBOLS_ONLY 1
double CalculateAdjustment()
{
    double add_coefficient = 1; // Might be necessary for correction coefficient calculation if two pairs are used for profit currency to account currency conversion. This is handled differently in MT5 version.
    if (ReferenceSymbol == NULL)
    {
        ReferenceSymbol = GetSymbolByCurrencies(ProfitCurrency, account_currency, FOREX_SYMBOLS_ONLY);
        if (ReferenceSymbol == NULL) ReferenceSymbol = GetSymbolByCurrencies(ProfitCurrency, account_currency, NONFOREX_SYMBOLS_ONLY);
        ReferenceSymbolMode = true;
        // Failed.
        if (ReferenceSymbol == NULL)
        {
            // Reversing currencies.
            ReferenceSymbol = GetSymbolByCurrencies(account_currency, ProfitCurrency, FOREX_SYMBOLS_ONLY);
            if (ReferenceSymbol == NULL) ReferenceSymbol = GetSymbolByCurrencies(account_currency, ProfitCurrency, NONFOREX_SYMBOLS_ONLY);
            ReferenceSymbolMode = false;
        }
        if (ReferenceSymbol == NULL)
        {
            // The condition checks whether we are caclulating conversion coefficient for the chart's symbol or for some other.
            // The error output is OK for the current symbol only because it won't be repeated ad infinitum.
            // It should be avoided for non-chart symbols because it will just flood the log.
            Print("Couldn't detect proper currency pair for adjustment calculation. Profit currency: ", ProfitCurrency, ". Account currency: ", account_currency, ". Trying to find a possible two-symbol combination.");
            if ((FindDoubleReferenceSymbol("USD"))  // USD should work in 99.9% of cases.
             || (FindDoubleReferenceSymbol("EUR"))  // For very rare cases.
             || (FindDoubleReferenceSymbol("GBP"))  // For extremely rare cases.
             || (FindDoubleReferenceSymbol("JPY"))) // For extremely rare cases.
            {
                Print("Converting via ", ReferenceSymbol, " and ", AdditionalReferenceSymbol, ".");
            }
            else
            {
                Print("Adjustment calculation critical failure. Failed both simple and two-pair conversion methods.");
                return 1;
            }
        }
    }
    if (AdditionalReferenceSymbol != NULL) // If two reference pairs are used.
    {
        // Calculate just the additional symbol's coefficient and then use it in final return's multiplication.
        MqlTick tick;
        SymbolInfoTick(AdditionalReferenceSymbol, tick);
        add_coefficient = GetCurrencyCorrectionCoefficient(tick, AdditionalReferenceSymbolMode);
    }
    MqlTick tick;
    SymbolInfoTick(ReferenceSymbol, tick);
    return GetCurrencyCorrectionCoefficient(tick, ReferenceSymbolMode) * add_coefficient;
}

//+---------------------------------------------------------------------------+
//| Returns a currency pair with specified base currency and profit currency. |
//+---------------------------------------------------------------------------+
string GetSymbolByCurrencies(const string base_currency, const string profit_currency, const uint symbol_type)
{
    // Cycle through all symbols.
    for (int s = 0; s < SymbolsTotal(false); s++)
    {
        // Get symbol name by number.
        string symbolname = SymbolName(s, false);
        string b_cur;

        // Normal case - Forex pairs:
        if (MarketInfo(symbolname, MODE_PROFITCALCMODE) == 0)
        {
            if (symbol_type == NONFOREX_SYMBOLS_ONLY) continue; // Avoid checking symbols of a wrong type.
            // Get its base currency.
            b_cur = SymbolInfoString(symbolname, SYMBOL_CURRENCY_BASE);
        }
        else // Weird case for brokers that set conversion pairs as CFDs.
        {
            if (symbol_type == FOREX_SYMBOLS_ONLY) continue; // Avoid checking symbols of a wrong type.
            // Get its base currency as the initial three letters - prone to huge errors!
            b_cur = StringSubstr(symbolname, 0, 3);
        }

        // Get its profit currency.
        string p_cur = SymbolInfoString(symbolname, SYMBOL_CURRENCY_PROFIT);

        // If the currency pair matches both currencies, select it in Market Watch and return its name.
        if ((b_cur == base_currency) && (p_cur == profit_currency))
        {
            // Select if necessary.
            if (!(bool)SymbolInfoInteger(symbolname, SYMBOL_SELECT)) SymbolSelect(symbolname, true);

            return symbolname;
        }
    }
    return NULL;
}

//+----------------------------------------------------------------------------+
//| Finds reference symbols using 2-pair method.                               |
//| Results are returned via reference parameters.                             |
//| Returns true if found the pairs, false otherwise.                          |
//+----------------------------------------------------------------------------+
bool FindDoubleReferenceSymbol(const string cross_currency)
{
    // A hypothetical example for better understanding:
    // The trader buys CAD/CHF.
    // account_currency is known = SEK.
    // cross_currency = USD.
    // profit_currency = CHF.
    // I.e., we have to buy dollars with francs (using the Ask price) and then sell those for SEKs (using the Bid price).

    ReferenceSymbol = GetSymbolByCurrencies(cross_currency, account_currency, FOREX_SYMBOLS_ONLY); 
    if (ReferenceSymbol == NULL) ReferenceSymbol = GetSymbolByCurrencies(cross_currency, account_currency, NONFOREX_SYMBOLS_ONLY);
    ReferenceSymbolMode = true; // If found, we've got USD/SEK.

    // Failed.
    if (ReferenceSymbol == NULL)
    {
        // Reversing currencies.
        ReferenceSymbol = GetSymbolByCurrencies(account_currency, cross_currency, FOREX_SYMBOLS_ONLY);
        if (ReferenceSymbol == NULL) ReferenceSymbol = GetSymbolByCurrencies(account_currency, cross_currency, NONFOREX_SYMBOLS_ONLY);
        ReferenceSymbolMode = false; // If found, we've got SEK/USD.
    }
    if (ReferenceSymbol == NULL)
    {
        Print("Error. Couldn't detect proper currency pair for 2-pair adjustment calculation. Cross currency: ", cross_currency, ". Account currency: ", account_currency, ".");
        return false;
    }

    AdditionalReferenceSymbol = GetSymbolByCurrencies(cross_currency, ProfitCurrency, FOREX_SYMBOLS_ONLY); 
    if (AdditionalReferenceSymbol == NULL) AdditionalReferenceSymbol = GetSymbolByCurrencies(cross_currency, ProfitCurrency, NONFOREX_SYMBOLS_ONLY);
    AdditionalReferenceSymbolMode = false; // If found, we've got USD/CHF. Notice that mode is swapped for cross/profit compared to cross/acc, because it is used in the opposite way.

    // Failed.
    if (AdditionalReferenceSymbol == NULL)
    {
        // Reversing currencies.
        AdditionalReferenceSymbol = GetSymbolByCurrencies(ProfitCurrency, cross_currency, FOREX_SYMBOLS_ONLY);
        if (AdditionalReferenceSymbol == NULL) AdditionalReferenceSymbol = GetSymbolByCurrencies(ProfitCurrency, cross_currency, NONFOREX_SYMBOLS_ONLY);
        AdditionalReferenceSymbolMode = true; // If found, we've got CHF/USD. Notice that mode is swapped for profit/cross compared to acc/cross, because it is used in the opposite way.
    }
    if (AdditionalReferenceSymbol == NULL)
    {
        Print("Error. Couldn't detect proper currency pair for 2-pair adjustment calculation. Cross currency: ", cross_currency, ". Chart's pair currency: ", ProfitCurrency, ".");
        return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//| Get profit correction coefficient based on current prices.       |
//| Valid for loss calculation only.                                 |
//+------------------------------------------------------------------+
double GetCurrencyCorrectionCoefficient(MqlTick &tick, const bool ref_symbol_mode)
{
    if ((tick.ask == 0) || (tick.bid == 0)) return -1; // Data is not yet ready.
    // Reverse quote.
    if (ref_symbol_mode)
    {
        // Using Buy price for reverse quote.
        return tick.ask;
    }
    // Direct quote.
    else
    {
        // Using Sell price for direct quote.
        return (1 / tick.bid);
    }
}

//+------------------------------------------------------------------+
//| Counts decimal places.                                           |
//+------------------------------------------------------------------+
int CountDecimalPlaces(double number)
{
    // 100 as maximum length of number.
    for (int i = 0; i < 100; i++)
    {
        double pwr = MathPow(10, i);
        if (MathRound(number * pwr) / pwr == number) return i;
    }
    return -1;
}
//+------------------------------------------------------------------+