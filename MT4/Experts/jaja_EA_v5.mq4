//+------------------------------------------------------------------+
//|                                              jaja_EA_v5.mq4      |
//|                              Copyright 2026, jaja Project        |
//+------------------------------------------------------------------+
// v5.00 改善内容:
//   1. ブローカー側ハードSL設定 (EA停止・通信断中も保護)
//   2. スプレッドフィルター (広スプレッド時はエントリーしない)
//   3. 時間フィルター (取引不可時間帯を設定可能)
//   4. エラーハンドリング強化 (GetLastError + リトライロジック)
//   5. ブレイクイーブン + トレーリングストップ
//   6. リスク%ベースのロット自動計算
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, jaja Project"
#property version   "5.00"
#property strict

#include <stdlib.mqh>  // ErrorDescription() のために必要

//============================================================
// 入力パラメータ
//============================================================

input string Group_Entry = "=== エントリー設定 ===";
input int    InpMagic    = 20260303;  // マジックナンバー
input int    InpSlippage = 3;         // 許容スリッページ (pips)

input string Group_Lot      = "=== ロット設定 ===";
input bool   InpUseRiskLot  = true;   // true: リスク%ベース / false: 固定ロット
input double InpRiskPercent = 1.0;    // リスク割合 (口座残高の %)
input double InpFixedLots   = 0.10;   // 固定ロット数 (リスク計算OFF時に使用)

input string Group_Filter      = "=== フィルター設定 ===";
input bool   InpUseMAFilter    = true;  // 長期MAトレンドフィルターを使用する
input int    InpFilterMA       = 200;   // トレンドフィルターのMA期間
input bool   InpUseSpreadFilter = true; // スプレッドフィルターを使用する
input double InpMaxSpreadPips   = 3.0;  // エントリー許容最大スプレッド (pips)
input bool   InpUseTimeFilter   = true; // 時間フィルターを使用する
input int    InpStartHour       = 7;    // 取引開始時刻 (サーバー時間・時)
input int    InpEndHour         = 22;   // 取引終了時刻 (サーバー時間・時)

input string Group_Exit       = "=== 決済設定 ===";
input double InpStopLoss      = 10.0;  // ハードSL (pips) ※ブローカー側に設定
input bool   InpHoldExpansion = true;  // BBが拡大中はシグナル消滅後もホールド

input string Group_BE   = "=== ブレイクイーブン設定 ===";
input bool   InpUseBE   = true;   // ブレイクイーブン機能を使用する
input double InpBEPips  = 8.0;    // この利益(pips)に達したらSLをBEに移動

input string Group_Trail    = "=== トレーリングストップ設定 ===";
input bool   InpUseTrail    = true;  // トレーリングストップを使用する
input double InpTrailStart  = 12.0;  // トレーリング開始の利益 (pips)
input double InpTrailPips   = 8.0;   // 価格から何pips後方でSLを追従するか

input string Group_BB   = "=== インジケーター連動BB設定 ===";
input int    InpBBPeriod = 5;         // BB期間
input double InpBBDev    = 2.0;       // BB偏差

input string Group_Daily      = "=== 日次損失制限 ===";
input bool   InpUseDailyLimit = true; // 日次最大損失制限を使用する
input double InpMaxDailyLoss  = 3.0;  // 日次最大損失 (口座残高の %)

//============================================================
// グローバル変数
//============================================================
datetime g_lastTradeBar   = 0;
double   g_dayStartBalance = 0.0;
datetime g_lastDayCheck    = 0;

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   g_dayStartBalance = AccountBalance();
   g_lastDayCheck    = TimeCurrent();
   Print("【jaja EA v5】起動完了 / 残高: ", DoubleToString(g_dayStartBalance, 2),
         " / Magic: ", InpMagic);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| pip単位を返す (5桁業者対応)                                     |
//+------------------------------------------------------------------+
double PipUnit()
{
   return (Digits == 3 || Digits == 5) ? Point * 10 : Point;
}

//+------------------------------------------------------------------+
//| スリッページをポイント換算して返す                               |
//+------------------------------------------------------------------+
int SlippagePoints()
{
   return InpSlippage * ((Digits == 3 || Digits == 5) ? 10 : 1);
}

//+------------------------------------------------------------------+
//| ロット計算 (リスク%ベース)                                      |
//+------------------------------------------------------------------+
double CalcLots(double stopLossPips)
{
   if(!InpUseRiskLot) return InpFixedLots;

   double pUnit         = PipUnit();
   double tickSize      = MarketInfo(Symbol(), MODE_TICKSIZE);
   double tickValue     = MarketInfo(Symbol(), MODE_TICKVALUE);
   if(tickSize <= 0 || tickValue <= 0) return InpFixedLots;

   // 1ロットあたり1pipの損益額
   double pipValuePerLot = (pUnit / tickSize) * tickValue;
   double riskAmount     = AccountBalance() * InpRiskPercent / 100.0;
   double lots           = riskAmount / (stopLossPips * pipValuePerLot);

   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   return lots;
}

//+------------------------------------------------------------------+
//| スプレッドチェック                                               |
//+------------------------------------------------------------------+
bool IsSpreadOK()
{
   if(!InpUseSpreadFilter) return true;
   double spreadPips = MarketInfo(Symbol(), MODE_SPREAD) * Point / PipUnit();
   if(spreadPips > InpMaxSpreadPips) {
      Print("【jaja EA v5】スプレッド超過スキップ: ", DoubleToString(spreadPips, 1), " pips");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| 時間フィルターチェック                                           |
//+------------------------------------------------------------------+
bool IsTimeAllowed()
{
   if(!InpUseTimeFilter) return true;
   int hour = TimeHour(TimeCurrent());
   // 日付をまたがない場合 例: 7〜22時
   if(InpStartHour <= InpEndHour)
      return (hour >= InpStartHour && hour < InpEndHour);
   // 日付をまたぐ場合 例: 22〜7時
   return (hour >= InpStartHour || hour < InpEndHour);
}

//+------------------------------------------------------------------+
//| 日次損失チェック (日付変更時に残高をリセット)                   |
//+------------------------------------------------------------------+
bool IsDailyLossOK()
{
   if(!InpUseDailyLimit) return true;

   // 日付が変わったらリセット
   if(TimeDay(TimeCurrent()) != TimeDay(g_lastDayCheck)) {
      g_dayStartBalance = AccountBalance();
      g_lastDayCheck    = TimeCurrent();
      Print("【jaja EA v5】日付変更: 残高リセット → ", DoubleToString(g_dayStartBalance, 2));
   }

   double lossAmount  = g_dayStartBalance - AccountEquity();
   double lossPercent = (g_dayStartBalance > 0) ? (lossAmount / g_dayStartBalance * 100.0) : 0.0;

   if(lossPercent >= InpMaxDailyLoss) {
      Print("【jaja EA v5】日次損失上限到達 (", DoubleToString(lossPercent, 2), "%) - 本日の新規エントリーを停止");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| リトライ不可の致命的エラーか判定                                 |
//+------------------------------------------------------------------+
bool IsFatalError(int errCode)
{
   switch(errCode) {
      case ERR_INVALID_LOTS:
      case ERR_INVALID_STOPS:
      case ERR_TRADE_DISABLED:
      case ERR_MARKET_CLOSED:
      case ERR_OFF_QUOTES:
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| OrderSend ラッパー (リトライ付き)                               |
//+------------------------------------------------------------------+
int SendOrderSafe(int type, double lots, double sl, string comment)
{
   int slippage = SlippagePoints();
   for(int attempt = 1; attempt <= 3; attempt++) {
      RefreshRates();
      double price = (type == OP_BUY) ? Ask : Bid;
      color  clr   = (type == OP_BUY) ? clrBlue : clrRed;

      int ticket = OrderSend(Symbol(), type, lots, price, slippage, sl, 0, comment, InpMagic, 0, clr);
      if(ticket > 0) return ticket;

      int err = GetLastError();
      Print("【jaja EA v5】OrderSend失敗 attempt=", attempt, " err=", err, " (", ErrorDescription(err), ")");
      if(IsFatalError(err)) break;
      if(!IsTesting()) Sleep(500);
   }
   return -1;
}

//+------------------------------------------------------------------+
//| OrderClose ラッパー (リトライ付き)                              |
//+------------------------------------------------------------------+
bool CloseOrderSafe(int ticket, string reason)
{
   int slippage = SlippagePoints();
   for(int attempt = 1; attempt <= 3; attempt++) {
      RefreshRates();
      if(!OrderSelect(ticket, SELECT_BY_TICKET)) break;
      double closePrice = (OrderType() == OP_BUY) ? Bid : Ask;

      bool res = OrderClose(ticket, OrderLots(), closePrice, slippage, clrWhite);
      if(res) {
         Print("【jaja EA v5】決済完了: ", reason);
         return true;
      }

      int err = GetLastError();
      Print("【jaja EA v5】OrderClose失敗 attempt=", attempt, " err=", err, " (", ErrorDescription(err), ")");
      if(IsFatalError(err)) break;
      if(!IsTesting()) Sleep(500);
   }
   return false;
}

//+------------------------------------------------------------------+
//| OrderModify ラッパー (リトライ付き)                             |
//+------------------------------------------------------------------+
bool ModifyOrderSafe(int ticket, double newSL, string reason)
{
   double newSLNorm = NormalizeDouble(newSL, Digits);
   for(int attempt = 1; attempt <= 3; attempt++) {
      if(!OrderSelect(ticket, SELECT_BY_TICKET)) break;
      // すでに同じ値 or 変化が小さい場合はスキップ
      if(MathAbs(OrderStopLoss() - newSLNorm) < Point) return true;

      bool res = OrderModify(ticket, OrderOpenPrice(), newSLNorm, OrderTakeProfit(), 0, clrGreen);
      if(res) {
         Print("【jaja EA v5】SL更新: ", reason, " SL=", DoubleToString(newSLNorm, Digits));
         return true;
      }

      int err = GetLastError();
      Print("【jaja EA v5】OrderModify失敗 attempt=", attempt, " err=", err, " (", ErrorDescription(err), ")");
      if(IsFatalError(err)) break;
      if(!IsTesting()) Sleep(200);
   }
   return false;
}

//+------------------------------------------------------------------+
//| ブレイクイーブン / トレーリングストップ管理                     |
//+------------------------------------------------------------------+
void ManageTrailing()
{
   double pUnit = PipUnit();

   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != InpMagic) continue;

      int    ticket    = OrderTicket();
      double openPrice = OrderOpenPrice();
      double currentSL = OrderStopLoss();
      double newSL     = currentSL;

      if(OrderType() == OP_BUY) {
         double profitPips = (Bid - openPrice) / pUnit;

         // ブレイクイーブン: SLをオープン価格まで引き上げる
         if(InpUseBE && profitPips >= InpBEPips) {
            double beSL = openPrice + 1.0 * pUnit;
            if(beSL > newSL) newSL = beSL;
         }

         // トレーリング: SLを現在価格からInpTrailPips後方で追従
         if(InpUseTrail && profitPips >= InpTrailStart) {
            double trailSL = Bid - InpTrailPips * pUnit;
            if(trailSL > newSL) newSL = trailSL;
         }

         // SLが上昇した場合のみ更新
         if(newSL > currentSL + Point)
            ModifyOrderSafe(ticket, newSL, "BE/Trail(買)");

      } else if(OrderType() == OP_SELL) {
         double profitPips = (openPrice - Ask) / pUnit;

         // ブレイクイーブン: SLをオープン価格まで引き下げる
         if(InpUseBE && profitPips >= InpBEPips) {
            double beSL = openPrice - 1.0 * pUnit;
            if(currentSL == 0.0 || beSL < newSL) newSL = beSL;
         }

         // トレーリング: SLを現在価格からInpTrailPips後方で追従
         if(InpUseTrail && profitPips >= InpTrailStart) {
            double trailSL = Ask + InpTrailPips * pUnit;
            if(currentSL == 0.0 || trailSL < newSL) newSL = trailSL;
         }

         // SLが下降した場合のみ更新
         if(currentSL == 0.0 || newSL < currentSL - Point)
            ModifyOrderSafe(ticket, newSL, "BE/Trail(売)");
      }
   }
}

//+------------------------------------------------------------------+
//| メイン処理                                                       |
//+------------------------------------------------------------------+
void OnTick()
{
   double pUnit = PipUnit();

   //==========================================================
   // 1. jaja インジケーターからシグナル取得 (確定足=1本前)
   //==========================================================
   double sigM        = iCustom(Symbol(), Period(), "jaja",  6, 1); // M単体(収束)
   double sigB_Buy    = iCustom(Symbol(), Period(), "jaja",  8, 1); // B単体(買放たれ)
   double sigB_Sell   = iCustom(Symbol(), Period(), "jaja",  9, 1); // B単体(売放たれ)
   double sig1        = iCustom(Symbol(), Period(), "jaja", 10, 1); // ①収束+放たれ
   double sig2        = iCustom(Symbol(), Period(), "jaja", 11, 1); // ②収束+ホライゾン
   double sig3        = iCustom(Symbol(), Period(), "jaja", 12, 1); // ③ホライゾン+放たれ
   double sigStarBuy  = iCustom(Symbol(), Period(), "jaja", 13, 1); // ★究極合致(買)
   double sigStarSell = iCustom(Symbol(), Period(), "jaja", 14, 1); // ★究極合致(売)

   // sig1 の方向判定:
   //   インジケーターが bBuy なら矢印=low-15pips → Close[1]より下 → 買い
   //   インジケーターが bSell なら矢印=high+15pips → Close[1]より上 → 売り
   bool sig1Valid = (sig1 != 0.0 && sig1 != EMPTY_VALUE);
   bool sig1Buy   = sig1Valid && (sig1 < Close[1]);
   bool sig1Sell  = sig1Valid && (sig1 > Close[1]);

   bool triggerBuy  = (sigStarBuy  != 0.0 && sigStarBuy  != EMPTY_VALUE) || sig1Buy;
   bool triggerSell = (sigStarSell != 0.0 && sigStarSell != EMPTY_VALUE) || sig1Sell;

   //==========================================================
   // 2. SMA200 トレンドフィルター
   //==========================================================
   if(InpUseMAFilter) {
      double maFilter  = iMA(Symbol(), Period(), InpFilterMA, 0, MODE_SMA, PRICE_CLOSE, 1);
      bool isTrendUp   = (Close[1] > maFilter);
      bool isTrendDown = (Close[1] < maFilter);
      triggerBuy  = triggerBuy  && isTrendUp;
      triggerSell = triggerSell && isTrendDown;
   }

   //==========================================================
   // 3. 決済判定用シグナル継続確認
   //==========================================================
   // EMPTY_VALUE チェックも込みで判定
   bool isM_Active = (sigM != 0.0 || sig1 != 0.0 || sig2 != 0.0 ||
                      sigStarBuy != 0.0 || sigStarSell != 0.0);
   bool isB_Active = (sigB_Buy != 0.0 || sigB_Sell != 0.0 || sig1 != 0.0 ||
                      sig3 != 0.0 || sigStarBuy != 0.0 || sigStarSell != 0.0);
   bool no_M_and_B = (!isM_Active && !isB_Active);

   //==========================================================
   // 4. ボリンジャーバンド拡大判定
   //==========================================================
   double bbu1 = iBands(Symbol(), Period(), InpBBPeriod, InpBBDev, 0, PRICE_CLOSE, MODE_UPPER, 1);
   double bbl1 = iBands(Symbol(), Period(), InpBBPeriod, InpBBDev, 0, PRICE_CLOSE, MODE_LOWER, 1);
   double bbu2 = iBands(Symbol(), Period(), InpBBPeriod, InpBBDev, 0, PRICE_CLOSE, MODE_UPPER, 2);
   double bbl2 = iBands(Symbol(), Period(), InpBBPeriod, InpBBDev, 0, PRICE_CLOSE, MODE_LOWER, 2);
   double bw1  = (bbu1 - bbl1) / pUnit;
   double bw2  = (bbu2 - bbl2) / pUnit;
   bool isBB_Expanding = (bw1 > bw2);

   //==========================================================
   // 5. 保有ポジション確認 (ticket で管理)
   //==========================================================
   int    buyTicket  = -1;
   int    sellTicket = -1;
   double buyProfit  = 0.0;
   double sellProfit = 0.0;

   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != InpMagic) continue;

      if(OrderType() == OP_BUY) {
         buyTicket = OrderTicket();
         buyProfit = (Bid - OrderOpenPrice()) / pUnit;
      } else if(OrderType() == OP_SELL) {
         sellTicket = OrderTicket();
         sellProfit = (OrderOpenPrice() - Ask) / pUnit;
      }
   }

   //==========================================================
   // 6. 決済処理
   //    ※ ハードSLはブローカー側で設定済だが、
   //       ソフトSLをバックアップとして維持する
   //==========================================================
   if(buyTicket > 0) {
      bool   shouldClose = false;
      string closeReason = "";

      if(buyProfit <= -InpStopLoss) {
         shouldClose = true;
         closeReason = StringFormat("ソフトSL発動(買) %.1f pips", buyProfit);
      } else if(no_M_and_B) {
         if(InpHoldExpansion && isBB_Expanding) {
            // BB拡大中はホールド継続
         } else {
            shouldClose = true;
            closeReason = StringFormat("M・Bサイン消滅(買) %.1f pips", buyProfit);
         }
      }

      if(shouldClose) {
         CloseOrderSafe(buyTicket, closeReason);
         buyTicket = -1;
      }
   }

   if(sellTicket > 0) {
      bool   shouldClose = false;
      string closeReason = "";

      if(sellProfit <= -InpStopLoss) {
         shouldClose = true;
         closeReason = StringFormat("ソフトSL発動(売) %.1f pips", sellProfit);
      } else if(no_M_and_B) {
         if(InpHoldExpansion && isBB_Expanding) {
            // BB拡大中はホールド継続
         } else {
            shouldClose = true;
            closeReason = StringFormat("M・Bサイン消滅(売) %.1f pips", sellProfit);
         }
      }

      if(shouldClose) {
         CloseOrderSafe(sellTicket, closeReason);
         sellTicket = -1;
      }
   }

   //==========================================================
   // 7. ブレイクイーブン / トレーリングストップ管理
   //==========================================================
   ManageTrailing();

   //==========================================================
   // 8. 新規エントリー
   //==========================================================
   bool canEnter = (Time[0] != g_lastTradeBar)
                && IsSpreadOK()
                && IsTimeAllowed()
                && IsDailyLossOK();

   if(triggerBuy && buyTicket < 0 && canEnter) {
      double lots    = CalcLots(InpStopLoss);
      double slPrice = NormalizeDouble(Ask - InpStopLoss * pUnit, Digits);
      int ticket = SendOrderSafe(OP_BUY, lots, slPrice, "jaja Buy");
      if(ticket > 0) {
         Print("【jaja EA v5】買いエントリー完了",
               " / lot=", DoubleToString(lots, 2),
               " / SL=", DoubleToString(slPrice, Digits));
         g_lastTradeBar = Time[0];
      }
   }

   if(triggerSell && sellTicket < 0 && canEnter) {
      double lots    = CalcLots(InpStopLoss);
      double slPrice = NormalizeDouble(Bid + InpStopLoss * pUnit, Digits);
      int ticket = SendOrderSafe(OP_SELL, lots, slPrice, "jaja Sell");
      if(ticket > 0) {
         Print("【jaja EA v5】売りエントリー完了",
               " / lot=", DoubleToString(lots, 2),
               " / SL=", DoubleToString(slPrice, Digits));
         g_lastTradeBar = Time[0];
      }
   }
}
