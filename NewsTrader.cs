// -------------------------------------------------------------------------------
//   Opens a buy/sell trade (random, chosen direction, or both directions) seconds before news release.
//   Sets SL and TP. Keeps updating them until the very release.
//   Can set SL to breakeven when unrealized profit = SL.
//   Alternatively, adds ATR based trailing stop.
//   Closes trade after given time period passes.
//   Version 1.09.
//   Copyright 2015-2022, EarnForex.com
//   https://www.earnforex.com/metatrader-expert-advisors/News-Trader/
// -------------------------------------------------------------------------------

using System;
using System.Linq;
using cAlgo.API;
using cAlgo.API.Indicators;
using cAlgo.API.Internals;
using cAlgo.Indicators;

namespace cAlgo
{
    [Robot(TimeZone = TimeZones.UTC, AccessRights = AccessRights.None)]
    public class NewsTrader : Robot
    {
        [Parameter(DefaultValue = 2022, MinValue = 1970)]
        public int Year { get; set; }

        [Parameter(DefaultValue = 4, MinValue = 1, MaxValue = 12)]
        public int Month { get; set; }

        [Parameter(DefaultValue = 26, MinValue = 1, MaxValue = 31)]
        public int Day { get; set; }

        [Parameter(DefaultValue = 0, MinValue = 0, MaxValue = 23)]
        public int Hour { get; set; }

        [Parameter(DefaultValue = 0, MinValue = 0, MaxValue = 59)]
        public int Minute { get; set; }

        [Parameter("Stop-Loss, pips", DefaultValue = 15, MinValue = 0)]
        public int StopLoss { get; set; }

        [Parameter("Take-Profit, pips", DefaultValue = 75, MinValue = 0)]
        public int TakeProfit { get; set; }

        [Parameter(DefaultValue = true)]
        public bool Buy { get; set; }

        [Parameter(DefaultValue = true)]
        public bool Sell { get; set; }

        [Parameter("Randomize Buy/Sell", DefaultValue = false)]
        public bool Rnd { get; set; }

        // Trailing Stop will supersede Breakeven Stop if true.
        [Parameter("Trailing Stop", DefaultValue = false)]
        public bool Trailing { get; set; }

        [Parameter("Breakeven Stop", DefaultValue = false)]
        public bool Breakeven { get; set; }

        [Parameter("Preadjust SL/TP", DefaultValue = false)]
        public bool PreAdjustSLTP { get; set; }

        [Parameter("Seconds Before News", DefaultValue = 10, MinValue = 1)]
        public int SecondsBefore { get; set; }

        [Parameter("Close After Seconds", DefaultValue = 3600, MinValue = 1)]
        public int CloseAfterSeconds { get; set; }

        [Parameter("Use ATR Position Sizing", DefaultValue = false)]
        public bool UseATR { get; set; }

        [Parameter("ATR Period", DefaultValue = 14, MinValue = 1)]
        public int ATR_Period { get; set; }

        [Parameter("ATR Multiplier for SL", DefaultValue = 1, MinValue = 0)]
        public double ATR_Multiplier_SL { get; set; }

        [Parameter("ATR Multiplier for TP", DefaultValue = 5, MinValue = 0)]
        public double ATR_Multiplier_TP { get; set; }

        [Parameter("Volume in Lots", DefaultValue = 0.01, MinValue = 0.01)]
        public double Lots { get; set; }

        [Parameter("Money Management", DefaultValue = true)]
        public bool MM { get; set; }

        [Parameter("Risk, %", DefaultValue = 1, MinValue = 0)]
        public double Risk { get; set; }

        [Parameter("Risk, Money", DefaultValue = 0, MinValue = 0)]
        public double MoneyRisk { get; set; }

        [Parameter("Fixed Balance", DefaultValue = 0, MinValue = 0)]
        public double FixedBalance { get; set; }

        [Parameter("Use Money Instead of %", DefaultValue = false)]
        public bool UseMoneyInsteadOfPercentage { get; set; }

        [Parameter("Use Equity Instead of Balance", DefaultValue = false)]
        public bool UseEquityInsteadOfBalance { get; set; }

        [Parameter("Show Timer", DefaultValue = true)]
        public bool ShowTimer { get; set; }

        [Parameter("Vertical Corner", DefaultValue = VerticalAlignment.Top)]
        public VerticalAlignment CornerVertical { get; set; }

        [Parameter("Horizontal Corner", DefaultValue = HorizontalAlignment.Left)]
        public HorizontalAlignment CornerHorizontal { get; set; }

        [Parameter(DefaultValue = 1)]
        public int Slippage { get; set; }

        [Parameter(DefaultValue = "NewsTrader")]
        public string Commentary { get; set; }

        // Indicator handles
        private AverageTrueRange ATR;

        private DateTime news_time;
        private bool CanTrade = false;

        private double SL, TP;

        private bool HaveLongPosition = false;
        private bool HaveShortPosition = false;

        protected string MyLabel
        {
            get { return string.Format("{0} {1} {2}", Commentary, Symbol.Name, TimeFrame); }
        }

        protected override void OnStart()
        {
            news_time = new DateTime(Year, Month, Day, Hour, Minute, 0);
            double min_lot = Symbol.VolumeInUnitsToQuantity(Symbol.VolumeInUnitsMin);
            double lot_step = Symbol.VolumeInUnitsToQuantity(Symbol.VolumeInUnitsStep);
            Print("Minimum lot: ", min_lot.ToString(), ", lot step: ", lot_step.ToString(), ".");
            if ((Lots < min_lot) && (!MM))
                Print("Lots should not be less than: ", min_lot.ToString(), ".");
            else
                CanTrade = true;

            if (ShowTimer)
            {
                Chart.DrawStaticText("NewsTraderTimer", "", CornerVertical, CornerHorizontal, Color.Red);
                // For smooth updates.
                Timer.Start(TimeSpan.FromMilliseconds(100));
            }

            if (UseATR)
            {
                ATR = Indicators.AverageTrueRange(ATR_Period, MovingAverageType.Simple);
            }

            // If UseATR = false, these values will be used. Otherwise, ATR values will be calculated later.
            SL = StopLoss;
            TP = TakeProfit;
        }

//+------------------------------------------------------------------+
//| Stops timer if needed.                                           |
//+------------------------------------------------------------------+
        protected override void OnStop()
        {
            if (ShowTimer)
            {
                Timer.Stop();
            }
        }

//+------------------------------------------------------------------+
//| Updates text about time left to news or passed after news.       |
//+------------------------------------------------------------------+
        protected override void OnTimer()
        {
            string text;

            TimeSpan difference = Time.Subtract(news_time);

            if (difference <= TimeSpan.FromMilliseconds(0))
                text = "Time to news:" + TimeDistance(difference.Negate());
            else
                text = "Time after news:" + TimeDistance(difference);
            Chart.DrawStaticText("NewsTraderTimer", text + "", CornerVertical, CornerHorizontal, Color.Red);
        }

        protected override void OnTick()
        {
            if (!CanTrade)
                return;

            if (UseATR)
            {
                // Getting the ATR values
                double ATR_value = ATR.Result.LastValue;
                SL = ATR_value * ATR_Multiplier_SL;
                TP = ATR_value * ATR_Multiplier_TP;
                SL /= Symbol.PipSize;
                TP /= Symbol.PipSize;
            }

            // Check what position is currently open
            GetPositionStates();

            // Adjust SL and TP of the current position
            if ((HaveLongPosition) || (HaveShortPosition))
                ControlPosition();
            else
            {
                TimeSpan difference = Time.Subtract(news_time).Negate();
                if ((difference <= TimeSpan.FromSeconds(SecondsBefore)) && (difference > TimeSpan.FromMilliseconds(0)))
                {
                    // Randomize entry.
                    if (Rnd)
                    {
                        Random r = new Random();
                        if (r.Next() % 2 == 1)
                            fBuy();
                        else
                            fSell();
                    }
                    else if ((Buy) && (Sell))
                    {
                        fSell();
                        fBuy();
                    }
                    else if (Buy)
                        fBuy();
                    else if (Sell)
                        fSell();
                }
            }
        }


//+------------------------------------------------------------------+
//| Check what positions are currently open.						 |
//+------------------------------------------------------------------+
        private void GetPositionStates()
        {
            foreach (var position in Positions)
            {
                if ((Symbol.Name == position.SymbolName) && (MyLabel == position.Label))
                {
                    if (position.TradeType == TradeType.Sell)
                        HaveShortPosition = true;
                    if (position.TradeType == TradeType.Buy)
                        HaveLongPosition = true;
                }
            }
        }


//+------------------------------------------------------------------+
//| Generic buy.													 |
//+------------------------------------------------------------------+
        private void fBuy()
        {
            ExecuteMarketRangeOrder(TradeType.Buy, Symbol.Name, LotsOptimized(), Slippage, Symbol.Ask, MyLabel, SL, TP, Commentary);
        }

//+------------------------------------------------------------------+
//| Generic sell.													 |
//+------------------------------------------------------------------+
        private void fSell()
        {
            ExecuteMarketRangeOrder(TradeType.Sell, Symbol.Name, LotsOptimized(), Slippage, Symbol.Bid, MyLabel, SL, TP, Commentary);
        }

//+------------------------------------------------------------------+
//| Add SL/TP, adjust SL/TP, set breakeven, close trade.	         |
//+------------------------------------------------------------------+
        private void ControlPosition()
        {
            foreach (var position in Positions)
            {
                if ((Symbol.Name == position.SymbolName) && (MyLabel == position.Label))
                {
                    TimeSpan difference = Time.Subtract(news_time);
                    if ((difference < TimeSpan.FromMilliseconds(0)) && (PreAdjustSLTP))
                    {
                        double new_sl = 0, new_tp = 0;
                        if (position.TradeType == TradeType.Buy)
                        {
                            new_sl = Math.Round(Symbol.Ask - SL * Symbol.PipSize, Symbol.Digits);
                            new_tp = Math.Round(Symbol.Ask + TP * Symbol.PipSize, Symbol.Digits);
                        }
                        else if (position.TradeType == TradeType.Sell)
                        {
                            new_sl = Math.Round(Symbol.Bid + SL * Symbol.PipSize, Symbol.Digits);
                            new_tp = Math.Round(Symbol.Bid - TP * Symbol.PipSize, Symbol.Digits);
                        }
                        if ((new_sl != position.StopLoss) || (new_tp != position.TakeProfit))
                        {
                            Print("Adjusting SL: ", new_sl, " and TP: ", new_tp, ".");
                            ModifyPosition(position, new_sl, new_tp);
                        }
                    }
                    // Check for breakeven or trade time out.
                    else
                    {
                        if ((!Trailing) && (Breakeven) && ((((position.TradeType == TradeType.Buy) && (Symbol.Ask - position.EntryPrice >= SL * Symbol.PipSize)) || ((position.TradeType == TradeType.Sell) && (position.EntryPrice - Symbol.Bid >= SL * Symbol.PipSize)))))
                        {
                            double new_sl = Math.Round(position.EntryPrice, Symbol.Digits);
                            if (new_sl != position.StopLoss)
                            {
                                Print("Moving SL to breakeven: ", new_sl, ".");
                                ModifyPosition(position, new_sl, position.TakeProfit);
                            }
                        }
                        else if ((Trailing) && ((((position.TradeType == TradeType.Buy) && (Symbol.Ask - position.StopLoss >= SL * Symbol.PipSize)) || ((position.TradeType == TradeType.Sell) && (position.StopLoss - Symbol.Bid >= SL * Symbol.PipSize)))))
                        {
                            double new_sl = 0;
                            if (position.TradeType == TradeType.Buy)
                                new_sl = Math.Round(Symbol.Ask - SL * Symbol.PipSize, Symbol.Digits);
                            else if (position.TradeType == TradeType.Sell)
                                new_sl = Math.Round(Symbol.Bid + SL * Symbol.PipSize, Symbol.Digits);
                            if (((position.TradeType == TradeType.Buy) && (new_sl > position.StopLoss)) || ((position.TradeType == TradeType.Sell) && (new_sl < position.StopLoss)))
                            {
                                Print("Moving trailing SL to ", new_sl, ".");
                                ModifyPosition(position, new_sl, position.TakeProfit);
                            }
                        }
                        if (CloseAfterSeconds > 0)
                        {
                            TimeSpan after_difference = Time.Subtract(news_time);
                            if (after_difference >= TimeSpan.FromSeconds(CloseAfterSeconds))
                            {
                                Print("Closing trade by time out.");
                                ClosePosition(position);
                            }
                        }
                    }
                }
            }
        }

//+------------------------------------------------------------------+
//| Format time distance from the number of seconds to normal string |
//| of years, days, hours, minutes, and seconds. 					 |
//| t - time difference								 			     |
//| Returns: formatted string.		 								 |
//+------------------------------------------------------------------+
        string TimeDistance(TimeSpan t)
        {
            if ((t < TimeSpan.FromSeconds(1)) && (t > TimeSpan.FromSeconds(1).Negate()))
                return (" 0 seconds");
            string s = "";
            int d = t.Days;
            int h = t.Hours;
            int m = t.Minutes;
            int sec = t.Seconds;

            if (d > 0)
                s += " " + d.ToString() + " day";
            if (d > 1)
                s += "s";

            if (h > 0)
                s += " " + h.ToString() + " hour";
            if (h > 1)
                s += "s";

            if (m > 0)
                s += " " + m.ToString() + " minute";
            if (m > 1)
                s += "s";

            if (sec > 0)
                s += " " + sec.ToString() + " second";
            if (sec > 1)
                s += "s";

            return (s);
        }

//+------------------------------------------------------------------+
//| Calculate position size depending on money management parameters.|
//+------------------------------------------------------------------+
        double LotsOptimized()
        {
            if (!MM)
                return (Symbol.QuantityToVolumeInUnits(Lots));

            double Size, RiskMoney, PositionSize = 0;

            if (Account.Asset.Name == "")
                return (0);

            if (FixedBalance > 0)
            {
                Size = FixedBalance;
            }
            else if (UseEquityInsteadOfBalance)
            {
                Size = Account.Equity;
            }
            else
            {
                Size = Account.Balance;
            }

            if (!UseMoneyInsteadOfPercentage)
                RiskMoney = Size * Risk / 100;
            else
                RiskMoney = MoneyRisk;

            double UnitCost = Symbol.PipValue;

            if ((SL != 0) && (UnitCost != 0))
                PositionSize = (int)Math.Round(RiskMoney / SL / UnitCost);

            Print(PositionSize);

            if (PositionSize < Symbol.VolumeInUnitsMin)
            {
                Print("Calculated position size (" + PositionSize + ") is less than minimum position size (" + Symbol.VolumeInUnitsMin + "). Setting position size to minimum.");
                PositionSize = Symbol.VolumeInUnitsMin;
            }
            else if (PositionSize > Symbol.VolumeInUnitsMax)
            {
                Print("Calculated position size (" + PositionSize + ") is greater than maximum position size (" + Symbol.VolumeInUnitsMax + "). Setting position size to maximum.");
                PositionSize = Symbol.VolumeInUnitsMax;
            }

            double LotStep = Symbol.VolumeInUnitsStep;
            double steps = PositionSize / LotStep;
            if (Math.Floor(steps) < steps)
            {
                Print("Calculated position size (" + PositionSize + ") uses uneven step size. Allowed step size = " + LotStep + ". Setting position size to " + (Math.Floor(steps) * LotStep) + ".");
                PositionSize = Math.Floor(steps) * LotStep;
            }

            return (PositionSize);
        }
    }
}
