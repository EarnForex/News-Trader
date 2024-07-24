//+------------------------------------------------------------------+
//|                                                   NewsTrader.mq5 |
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
#property description "Closes trade after given time period passes."

#include <Trade/Trade.mqh>
#include <Trade/OrderInfo.mqh>
#include <Trade/PositionInfo.mqh>

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
input int StopLoss = 15; // Stop-loss in broker's pips
input int TakeProfit = 75; // Take-profit in broker's pips.
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
bool HaveBuyPending = false, HaveSellPending = false;
bool ECN_Mode, Hedging_Mode;
bool BuyOrderAccepted = false, SellOrderAccepted = false;

int news_time;
bool CanTrade = false;
bool Terminal_Trade_Allowed = true;

double SL, TP;

// For tick value adjustment:
string AccountCurrency = "";
string ProfitCurrency = "";
string BaseCurrency = "";
ENUM_SYMBOL_CALC_MODE CalcMode;
string ReferencePair = NULL;
bool ReferenceSymbolMode;

// Main trading objects:
CTrade *Trade;
CPositionInfo PositionInfo;

void OnInit()
{
    HaveBuyPending = false; HaveSellPending = false;
    BuyOrderAccepted = false; SellOrderAccepted = false;
    CanTrade = false;
    Terminal_Trade_Allowed = true;
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

    Trade = new CTrade;
    Trade.SetDeviationInPoints(Slippage);
    Trade.SetExpertMagicNumber(Magic);

    if (BEExtraProfit > BEOnProfit) Print("Extra profit for breakeven shouldn't be greater than the profit to trigger breakeven parameter. Please check your input parameters.");
}

//+------------------------------------------------------------------+
//| Deletes graphical object if needed.                              |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    ObjectDelete(ChartID(), "NewsTraderTimer");
    delete Trade;
}

//+------------------------------------------------------------------+
//| Updates text about time left to news or passed after news.       |
//+------------------------------------------------------------------+
void OnTimer()
{
    string text;
    int difference = (int)TimeCurrent() - news_time;
    if (difference <= 0) text = "Time to news: " + TimeDistance(-difference);
    else text = "Time after news: " + TimeDistance(difference);
    ObjectSetString(0, "NewsTraderTimer", OBJPROP_TEXT, text + ".");
    ObjectSetInteger(0, "NewsTraderTimer", OBJPROP_FONTSIZE, FontSize);
    ObjectSetString(0, "NewsTraderTimer", OBJPROP_FONT, Font);
    ObjectSetInteger(0, "NewsTraderTimer", OBJPROP_COLOR, FontColor);
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Format time distance from the number of seconds to normal string |
//| of years, days, hours, minutes, and seconds.                     |
//| t - number of seconds                                            |
//| Returns: formatted string.                                       |
//+------------------------------------------------------------------+
string TimeDistance(int t)
{
    if (t == 0) return("0 seconds");
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

    StringTrimLeft(s);
    return s;
}

//+------------------------------------------------------------------+
//| Check every tick.                                                |
//+------------------------------------------------------------------+
void OnTick()
{
    AccountCurrency = AccountInfoString(ACCOUNT_CURRENCY);
    // A rough patch for cases when account currency is set as RUR instead of RUB.
    if (AccountCurrency == "RUR") AccountCurrency = "RUB";
    ProfitCurrency = SymbolInfoString(Symbol(), SYMBOL_CURRENCY_PROFIT);
    if (ProfitCurrency == "RUR") ProfitCurrency = "RUB";
    BaseCurrency = SymbolInfoString(Symbol(), SYMBOL_CURRENCY_BASE);
    if (BaseCurrency == "RUR") BaseCurrency = "RUB";

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

    ENUM_ACCOUNT_MARGIN_MODE Account_Mode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
    if (Account_Mode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING) Hedging_Mode = true;
    else Hedging_Mode = false;

    // Do nothing if it is too early.
    int time = (int)TimeCurrent();
    if (time < news_time - SecondsBefore) return;

    if (UseATR)
    {
        // Getting the ATR values.
        double ATR;
        double ATR_buffer[1];
        int ATR_handle = iATR(NULL, 0, ATR_Period);
        if (CopyBuffer(ATR_handle, 0, 1, 1, ATR_buffer) != 1)
        {
            Print("ATR data not ready!");
            return;
        }
        ATR = ATR_buffer[0];
        SL = ATR * ATR_Multiplier_SL;
        if (SL <= (SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL) + SymbolInfoInteger(Symbol(), SYMBOL_SPREAD)) * _Point) SL = (SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL) + SymbolInfoInteger(Symbol(), SYMBOL_SPREAD)) * _Point;
        TP = ATR * ATR_Multiplier_TP;
        if (TP <= (SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL) + SymbolInfoInteger(Symbol(), SYMBOL_SPREAD)) * _Point) TP = (SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL) + SymbolInfoInteger(Symbol(), SYMBOL_SPREAD)) * _Point;
        SL /= _Point;
        TP /= _Point;
    }

    // Check what position is currently open. Only in hedging mode.
    if (Hedging_Mode) GetPositionStates();
    // Control pending orders in netting mode.
    else if (Direction == Both) ControlPending();

    // Adjust SL and TP of the current position. Only in hedging mode.
    if (((HaveLongPosition) || (HaveShortPosition)) && (Hedging_Mode)) ControlPosition();
    // In the netting mode: Adjust SL and TP of the current position
    else if ((PositionSelect(Symbol())) && (!Hedging_Mode)) ControlPosition();
    else
    {
        // Time to news is less or equal to SecondsBefore but is not negative.
        if ((news_time - time <= SecondsBefore) && (news_time > time))
        {
            // Prevent position opening when spreads are too wide (bigger than StopLoss input).
            if (Hedging_Mode)
            {
                long spread = SymbolInfoInteger(Symbol(), SYMBOL_SPREAD);
                if ((SpreadFuse) && (spread >= StopLoss))
                {
                    Print(Symbol(), ": Spread fuse prevents positions from opening. Current spread: ", spread, " points.");
                    return;
                }
            }
            if (Direction == Buy)
            {
                if (!BuyOrderAccepted) fBuy();
            }
            else if (Direction == Sell)
            {
                if (!SellOrderAccepted) fSell();
            }
            else if (Direction == Both)
            {
                if (Hedging_Mode)
                {
                    if (!BuyOrderAccepted) fBuy();
                    if (!SellOrderAccepted) fSell();
                }
                else if ((!HaveBuyPending) || (!HaveSellPending))
                {
                    if (!BuyOrderAccepted) fBuy_Pending();
                    if (!SellOrderAccepted) fSell_Pending();
                }
            }
            else if (Direction == Random)
            {
                if ((!BuyOrderAccepted) && (!SellOrderAccepted))
                {
                    MathSrand((uint)TimeCurrent());
                    if (MathRand() % 2 == 1) fBuy();
                    else fSell();
                }
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
    int total = PositionsTotal();
    for (int cnt = 0; cnt < total; cnt++)
    {
        if (PositionGetSymbol(cnt) != Symbol()) continue;
        if (PositionGetInteger(POSITION_MAGIC) != Magic) continue;

        if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) HaveLongPosition = true;
        else if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) HaveShortPosition = true;
    }
}

//+------------------------------------------------------------------+
//| Add SL/TP, adjust SL/TP, set breakeven, close trade.             |
//+------------------------------------------------------------------+
void ControlPosition()
{
    int total = PositionsTotal();
    for (int cnt = total - 1; cnt >= 0; cnt--)
    {
        if (PositionGetSymbol(cnt) != Symbol()) continue;
        if (Hedging_Mode)
        {
            if (PositionGetInteger(POSITION_MAGIC) != Magic) continue;
        }

        double Ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
        double Bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);

        ulong ticket = PositionGetInteger(POSITION_TICKET);

        int time = (int)TimeCurrent();
        // Need to adjust or add SL/TP
        if (time < news_time)
        {
            double new_sl = 0, new_tp = 0;
            if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
            {
                new_sl = NormalizeDouble(Ask - SL * _Point, Digits());
                new_tp = NormalizeDouble(Ask + TP * _Point, Digits());
            }
            else if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
            {
                new_sl = NormalizeDouble(Bid + SL * _Point, Digits());
                new_tp = NormalizeDouble(Bid - TP * _Point, Digits());
            }
            if ((((new_sl != NormalizeDouble(PositionGetDouble(POSITION_SL), Digits())) || (new_tp != NormalizeDouble(PositionGetDouble(POSITION_TP), Digits()))) && (PreAdjustSLTP)) ||
                    (((PositionGetDouble(POSITION_SL) == 0) || (PositionGetDouble(POSITION_TP) == 0)) && (ECN_Mode)))
            {
                Print("Adjusting SL: ", DoubleToString(new_sl, _Digits), " and TP: ", DoubleToString(new_tp, _Digits), ".");
                for (int i = 0; i < 10; i++)
                {
                    bool result = Trade.PositionModify(ticket, new_sl, new_tp);
                    if (result) return;
                    else Print("Error modifying position: ", GetLastError());
                }
            }
        }
        // Check for breakeven or trade time out.
        else
        {
            // Breakeven.
            if (((TrailingStop == Breakeven) || (TrailingStop == NormalPlusBE)) && ((((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) && (Bid - PositionGetDouble(POSITION_PRICE_OPEN) >= BEOnProfit * _Point)) || ((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) && (PositionGetDouble(POSITION_PRICE_OPEN) - Ask >= BEOnProfit * _Point)))))
            {
                double new_sl = NormalizeDouble(PositionGetDouble(POSITION_PRICE_OPEN), Digits());
                if (BEExtraProfit > 0) // Breakeven extra profit?
                {
                    if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) new_sl += BEExtraProfit * _Point; // For buys.
                    else new_sl -= BEExtraProfit * _Point; // For sells.
                    new_sl = NormalizeDouble(new_sl, _Digits);
                }
                if (((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) && (new_sl > PositionGetDouble(POSITION_SL))) || ((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) && ((new_sl < PositionGetDouble(POSITION_SL))  || (PositionGetDouble(POSITION_SL) == 0)))) // Avoid moving SL to BE if this SL is already there or in a better position.
                {
                    Print("Moving SL to breakeven: ", DoubleToString(new_sl, _Digits), ".");
                    for (int i = 0; i < 10; i++)
                    {
                        bool result = Trade.PositionModify(ticket, new_sl, PositionGetDouble(POSITION_TP));
                        if (result) break;
                        else Print("Position modification error: ", GetLastError());
                    }
                }
            }
            // Trailing stop.
            if (((TrailingStop == Normal) || (TrailingStop == NormalPlusBE)) && ((TSOnProfit == 0) || ((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) && (Bid - PositionGetDouble(POSITION_PRICE_OPEN) >= TSOnProfit * _Point)) || ((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) && (PositionGetDouble(POSITION_PRICE_OPEN) - Ask >= TSOnProfit * _Point))))
            {
                double new_sl = 0;
                if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) new_sl = NormalizeDouble(Bid - SL * _Point, Digits());
                else if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) new_sl = NormalizeDouble(Ask + SL * _Point, Digits());
                if (((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) && (new_sl > PositionGetDouble(POSITION_SL))) || ((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) && ((new_sl < PositionGetDouble(POSITION_SL)) || (PositionGetDouble(POSITION_SL) == 0)))) // Avoid moving the SL if this SL is already in a better position.
                {
                    Print("Moving trailing SL to ", DoubleToString(new_sl, _Digits), ".");
                    for (int i = 0; i < 10; i++)
                    {
                        bool result = Trade.PositionModify(ticket, new_sl, PositionGetDouble(POSITION_TP));
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
                    if (!Trade.PositionClose(ticket))
                    {
                        Print("PositionClose() failed: ", GetLastError());
                    }
                }
            }
            // Perform OCO (one cancels other).
            if ((Direction == Both) && (!Hedging_Mode))
            {
                for (int i = OrdersTotal() - 1; i >= 0; i--)
                {
                    ulong order_ticket = OrderGetTicket(i);
                    if ((OrderGetString(ORDER_SYMBOL) == Symbol()) && (OrderGetInteger(ORDER_MAGIC) == Magic))
                    {
                        Trade.OrderDelete(order_ticket);
                        break;
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Adjust SL/TP of pending orders in "Both" direction,              |
//| in netting mode only.                                            |
//+------------------------------------------------------------------+
void ControlPending()
{
    int time = (int)TimeCurrent();
    // Need to adjust or add SL/TP
    if (time < news_time)
    {
        for (int i = 0; i < OrdersTotal(); i++)
        {
            ulong ticket = OrderGetTicket(i);
            if ((OrderGetString(ORDER_SYMBOL) == Symbol()) && (OrderGetInteger(ORDER_MAGIC) == Magic))
            {
                double Ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
                double Bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);

                double entry = 0, new_sl = 0, new_tp = 0;
                if (OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_BUY_STOP)
                {
                    HaveBuyPending = true;
                    entry = NormalizeDouble(Bid + SL * _Point, Digits()); // Entry is at original Sell's SL.
                    new_sl = NormalizeDouble(Ask - SL * _Point, Digits());
                    new_tp = NormalizeDouble(Ask + TP * _Point, Digits());
                }
                else if (OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_SELL_STOP)
                {
                    HaveSellPending = true;
                    entry = NormalizeDouble(Ask - SL * _Point, Digits()); // Entry is at original Buy's SL.
                    new_sl = NormalizeDouble(Bid + SL * _Point, Digits());
                    new_tp = NormalizeDouble(Bid - TP * _Point, Digits());
                }
                if ((entry != NormalizeDouble(OrderGetDouble(ORDER_PRICE_OPEN), Digits())) || (new_sl != NormalizeDouble(OrderGetDouble(ORDER_SL), Digits())) || (new_tp != NormalizeDouble(OrderGetDouble(ORDER_TP), Digits())))
                {
                    Print("Adjusting Entry: ", DoubleToString(entry, _Digits), ", SL: ", DoubleToString(new_sl, _Digits), ", and TP: ", DoubleToString(new_tp, _Digits), ".");
                    if (!Trade.OrderModify(ticket, entry, new_sl, new_tp, 0, 0))
                    {
                        Print("Order modify error: ", GetLastError());
                    }
                }
            }
        }
    }
    else if (CloseAfterSeconds > 0)
    {
        for (int i = 0; i < OrdersTotal(); i++)
        {
            ulong ticket = OrderGetTicket(i);
            if ((OrderGetString(ORDER_SYMBOL) == Symbol()) && (OrderGetInteger(ORDER_MAGIC) == Magic))
            {
                if (time - news_time >= CloseAfterSeconds)
                {
                    Trade.OrderDelete(ticket);
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
    double lots = LotsOptimized(ORDER_TYPE_BUY);
    double Ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
    // Bid and Ask are swapped to preserve the probabilities and decrease/increase profit/loss size.
    double new_sl = 0, new_tp = 0;
    if (!ECN_Mode)
    {
        new_sl = NormalizeDouble(Ask - SL * _Point, Digits());
        new_tp = NormalizeDouble(Ask + TP * _Point, Digits());
    }
    if (!Trade.PositionOpen(Symbol(), ORDER_TYPE_BUY, lots, Ask, new_sl, new_tp, Commentary))
    {
        PrintFormat("Unable to open BUY: %s - %d", Trade.ResultRetcodeDescription(), Trade.ResultRetcode());
    }
    else BuyOrderAccepted = true;
}

//+------------------------------------------------------------------+
//| Generic pending buy.                                             |
//+------------------------------------------------------------------+
void fBuy_Pending()
{
    Print("Opening pending Buy.");
    double Bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
    double Ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
    // For Buy pending order, Entry is at Bid + SL (where Sell trade would close).
    double entry = 0, new_sl = 0, new_tp = 0;
    entry = NormalizeDouble(Bid + SL * _Point, Digits()); // Entry is at original Sell's SL.
    new_sl = NormalizeDouble(Ask - SL * _Point, Digits()); // Buy's SL will be at original Buy's SL location.
    new_tp = NormalizeDouble(Ask + TP * _Point, Digits()); // Same with TP.
    double lots = LotsOptimized(ORDER_TYPE_BUY, entry);
    if (!Trade.OrderOpen(Symbol(), ORDER_TYPE_BUY_STOP, lots, 0, entry, new_sl, new_tp, 0, 0, Commentary))
    {
        PrintFormat("Unable to open Pending BUY: %s - %d", Trade.ResultRetcodeDescription(), Trade.ResultRetcode());
    }
    else BuyOrderAccepted = true;
}

//+------------------------------------------------------------------+
//| Generic sell.                                                    |
//+------------------------------------------------------------------+
void fSell()
{
    Print("Opening Sell.");
    double lots = LotsOptimized(ORDER_TYPE_SELL);
    double Bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
    // Bid and Ask are swapped to preserve the probabilities and decrease/increase profit/loss size.
    double new_sl = 0, new_tp = 0;
    if (!ECN_Mode)
    {
        new_sl = NormalizeDouble(Bid + SL * _Point, Digits());
        new_tp = NormalizeDouble(Bid - TP * _Point, Digits());
    }
    if (!Trade.PositionOpen(_Symbol, ORDER_TYPE_SELL, lots, Bid, new_sl, new_tp, Commentary))
    {
        PrintFormat("Unable to open SELL: %s - %d", Trade.ResultRetcodeDescription(), Trade.ResultRetcode());
    }
    else SellOrderAccepted = true;    
}

//+------------------------------------------------------------------+
//| Generic pending sell.                                            |
//+------------------------------------------------------------------+
void fSell_Pending()
{
    Print("Opening pending Sell.");
    double Bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
    double Ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
    // For Sell pending order, Entry is at Ask - SL (where Buy trade would close).
    double entry = 0, new_sl = 0, new_tp = 0;
    entry = NormalizeDouble(Ask - SL * _Point, Digits()); // Entry is at original Buy's SL.
    new_sl = NormalizeDouble(Bid + SL * _Point, Digits()); // Sell's SL will be at original Sell's SL location.
    new_tp = NormalizeDouble(Bid - TP * _Point, Digits()); // Same with TP.
    double lots = LotsOptimized(ORDER_TYPE_SELL, entry);
    if (!Trade.OrderOpen(Symbol(), ORDER_TYPE_SELL_STOP, lots, 0, entry, new_sl, new_tp, 0, 0, Commentary))
    {
        PrintFormat("Unable to open Pending SELL: %s - %d", Trade.ResultRetcodeDescription(), Trade.ResultRetcode());
    }
    else SellOrderAccepted = true;
}

//+------------------------------------------------------------------+
//| Calculates unit cost based on profit calculation mode.           |
//+------------------------------------------------------------------+
double CalculateUnitCost()
{
    double UnitCost;
    // CFD.
    if (((CalcMode == SYMBOL_CALC_MODE_CFD) || (CalcMode == SYMBOL_CALC_MODE_CFDINDEX) || (CalcMode == SYMBOL_CALC_MODE_CFDLEVERAGE)))
        UnitCost = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE) * SymbolInfoDouble(Symbol(), SYMBOL_TRADE_CONTRACT_SIZE);
    // With Forex and futures instruments, tick value already equals 1 unit cost.
    else UnitCost = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE_LOSS);
    
    return UnitCost;
}

//+-----------------------------------------------------------------------------------+
//| Calculates necessary adjustments for cases when GivenCurrency != AccountCurrency. |
//+-----------------------------------------------------------------------------------+
double CalculateAdjustment()
{
    if (ReferencePair == NULL)
    {
        ReferencePair = GetSymbolByCurrencies(ProfitCurrency, AccountCurrency);
        ReferenceSymbolMode = true;
        // Failed.
        if (ReferencePair == NULL)
        {
            // Reversing currencies.
            ReferencePair = GetSymbolByCurrencies(AccountCurrency, ProfitCurrency);
            ReferenceSymbolMode = false;
        }
    }
    if (ReferencePair == NULL)
    {
        Print("Error! Cannot detect proper currency pair for adjustment calculation: ", ProfitCurrency, ", ", AccountCurrency, ".");
        ReferencePair = Symbol();
        return 1;
    }
    MqlTick tick;
    SymbolInfoTick(ReferencePair, tick);
    return GetCurrencyCorrectionCoefficient(tick);
}

//+---------------------------------------------------------------------------+
//| Returns a currency pair with specified base currency and profit currency. |
//+---------------------------------------------------------------------------+
string GetSymbolByCurrencies(string base_currency, string profit_currency)
{
    // Cycle through all symbols.
    for (int s = 0; s < SymbolsTotal(false); s++)
    {
        // Get symbol name by number.
        string symbolname = SymbolName(s, false);

        // Skip non-Forex pairs.
        if ((SymbolInfoInteger(symbolname, SYMBOL_TRADE_CALC_MODE) != SYMBOL_CALC_MODE_FOREX) && (SymbolInfoInteger(symbolname, SYMBOL_TRADE_CALC_MODE) != SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE)) continue;

        // Get its base currency.
        string b_cur = SymbolInfoString(symbolname, SYMBOL_CURRENCY_BASE);
        if (b_cur == "RUR") b_cur = "RUB";

        // Get its profit currency.
        string p_cur = SymbolInfoString(symbolname, SYMBOL_CURRENCY_PROFIT);
        if (p_cur == "RUR") p_cur = "RUB";

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

//+------------------------------------------------------------------+
//| Get correction coefficient based on currency, trade direction,   |
//| and current prices.                                              |
//+------------------------------------------------------------------+
double GetCurrencyCorrectionCoefficient(MqlTick &tick)
{
    if ((tick.ask == 0) || (tick.bid == 0)) return -1; // Data is not yet ready.
    // Reverse quote.
    if (ReferenceSymbolMode)
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
//| Calculate position size depending on money management parameters.|
//+------------------------------------------------------------------+
double LotsOptimized(ENUM_ORDER_TYPE dir, double pending_entry = 0)
{
    if (!MM) return (Lots);

    double Size, RiskMoney, PositionSize = 0;

    if (AccountInfoString(ACCOUNT_CURRENCY) == "") return 0;

    if (FixedBalance > 0)
    {
        Size = FixedBalance;
    }
    else if (UseEquityInsteadOfBalance)
    {
        Size = AccountInfoDouble(ACCOUNT_EQUITY);
    }
    else
    {
        Size = AccountInfoDouble(ACCOUNT_BALANCE);
    }

    if (!UseMoneyInsteadOfPercentage) RiskMoney = Size * Risk / 100;
    else RiskMoney = MoneyRisk;

    double UnitCost = CalculateUnitCost();

    // If profit currency is different from account currency and Symbol is not a Forex pair or futures (CFD, and so on).
    if ((ProfitCurrency != AccountCurrency) && (CalcMode != SYMBOL_CALC_MODE_FOREX) && (CalcMode != SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE) && (CalcMode != SYMBOL_CALC_MODE_FUTURES) && (CalcMode != SYMBOL_CALC_MODE_EXCH_FUTURES) && (CalcMode != SYMBOL_CALC_MODE_EXCH_FUTURES_FORTS))
    {
        double CCC = CalculateAdjustment(); // Valid only for loss calculation.
        // Adjust the unit cost.
        UnitCost *= CCC;
    }

    // If account currency == pair's base currency, adjust UnitCost to future rate (SL). Works only for Forex pairs.
    if ((AccountCurrency == BaseCurrency) && ((CalcMode == SYMBOL_CALC_MODE_FOREX) || (CalcMode == SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE)))
    {
        double current_rate = 1, future_rate = 1;
        if (dir == ORDER_TYPE_BUY)
        {
            if (pending_entry == 0) current_rate = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            else current_rate = pending_entry;
            future_rate = current_rate - SL * _Point;
        }
        else if (dir == ORDER_TYPE_SELL)
        {
            if (pending_entry == 0) current_rate = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            else current_rate = pending_entry;
            future_rate = current_rate + SL * _Point;
        }
        if (future_rate == 0) future_rate = _Point; // Zero divide prevention.
        UnitCost *= (current_rate / future_rate);
    }

    double TickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double LotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    int LotStep_digits = CountDecimalPlaces(LotStep);
    if ((SL != 0) && (UnitCost != 0) && (TickSize != 0)) PositionSize = NormalizeDouble(RiskMoney / (SL * _Point * UnitCost / TickSize), LotStep_digits);

    if (PositionSize < SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN))
    {
        Print("Calculated position size (" + DoubleToString(PositionSize, 2) + ") is less than minimum position size (" + DoubleToString(SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN), 2) + "). Setting position size to minimum.");
        PositionSize = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
    }
    else if (PositionSize > SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX))
    {
        Print("Calculated position size (" + DoubleToString(PositionSize, 2) + ") is greater than maximum position size (" + DoubleToString(SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX), 2) + "). Setting position size to maximum.");
        PositionSize = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
    }

    double steps = PositionSize / LotStep;
    if (MathFloor(steps) < steps)
    {
        Print("Calculated position size (" + DoubleToString(PositionSize, 2) + ") uses uneven step size. Allowed step size = " + DoubleToString(SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP), 2) + ". Setting position size to " + DoubleToString(MathFloor(steps) * LotStep, 2) + ".");
        PositionSize = MathFloor(steps) * LotStep;
    }

    return PositionSize;
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