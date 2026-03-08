//+------------------------------------------------------------------+
//|                                          jaja_EA_Scalping.mq4    |
//|                                     Copyright 2026, Gemini Custom|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Gemini"
#property version   "2.00"
#property strict

// --- 入力パラメータ ---
input string Group_Entry = "--- エントリー設定 ---";
input double InpLots     = 0.10;      // エントリーロット数 (0.10 = 1万通貨)
input int    InpSlippage = 10;        // 許容スリッページ (FXTFなど極小スプレッド業者は10=1.0pips等タイトに)
input int    InpMagic    = 20260302;  // マジックナンバー

input string Group_Exit  = "--- スキャルピング決済(Exit)設定 ---";
input double InpTakeProfit   = 5.0;   // 利確Pips (スキャルピング用に数pipsで設定)
input double InpStopLoss     = 5.0;   // 損切Pips (早めの損切りで資金を守る)
input double InpTrailingStop = 0.0;   // トレーリング幅Pips (0.0で無効化。スキャル時は固定利確推奨)

input string Group_BBExit  = "--- 停滞判定(BB再収束)設定 ---";
input double InpCloseSqzPips = 5.0;   // BB幅がこのPips以下なら「相場の勢い消失」とみなして即撤退
input int    InpWaitBars     = 1;     // エントリー後、最低何本は決済を我慢するか

input string Group_BB    = "--- インジケーター連動BB設定 ---";
input int    InpMA1      = 5;         // BB期間
input double InpBBDev    = 2.0;       // BB偏差

// 連続エントリー防止用の記録変数
datetime lastTradeBar = 0;

//+------------------------------------------------------------------+
//| ティック受信ごとのメイン処理                                     |
//+------------------------------------------------------------------+
void OnTick()
{
   double pUnit = (Digits == 3 || Digits == 5) ? Point * 10 : Point;

   // 1. jaja.mq4からシグナルを取得（1本前の確定足を参照）
   // ★究極合致のシグナル (Buffer 13=買い, 14=売り)
   double sigBuyStar  = iCustom(Symbol(), Period(), "jaja", 13, 1);
   double sigSellStar = iCustom(Symbol(), Period(), "jaja", 14, 1);
   
   // ①収束+放たれのシグナル (Buffer 10)
   // ※Buffer 10は買いと売りで共有されているため、描画位置(ローソク足より上か下か)で売買を判定します
   double sig1 = iCustom(Symbol(), Period(), "jaja", 10, 1);

   // シグナル判定フラグ
   bool isBuyStar  = (sigBuyStar != 0.0 && sigBuyStar != EMPTY_VALUE);
   bool isSellStar = (sigSellStar != 0.0 && sigSellStar != EMPTY_VALUE);
   
   // ①のシグナルが終値より下にあれば「買い」、上にあれば「売り」
   bool isBuy1  = (sig1 != 0.0 && sig1 != EMPTY_VALUE && sig1 < Close[1]);
   bool isSell1 = (sig1 != 0.0 && sig1 != EMPTY_VALUE && sig1 > Close[1]);

   // 【スキャルピング用：最終エントリートリガー】
   // ★究極合致、または ①収束+放たれ のどちらかが出たらエントリー
   bool triggerBuy  = (isBuyStar || isBuy1);
   bool triggerSell = (isSellStar || isSell1);


   // 2. 現在のボリンジャーバンド幅を計算（停滞判定用）
   double bbu = iBands(Symbol(), Period(), InpMA1, InpBBDev, 0, PRICE_CLOSE, MODE_UPPER, 1);
   double bbl = iBands(Symbol(), Period(), InpMA1, InpBBDev, 0, PRICE_CLOSE, MODE_LOWER, 1);
   double currentBW = (bbu - bbl) / pUnit;
   bool isSqueezed = (currentBW < InpCloseSqzPips);


   // 3. 現在の保有ポジションを確認と決済ロジック
   int totalOrders = OrdersTotal();
   bool hasBuy = false;
   bool hasSell = false;

   for(int i = totalOrders - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == InpMagic)
         {
            int barsHeld = iBarShift(Symbol(), Period(), OrderOpenTime());
            int barsToSearch = barsHeld + 1; 
            
            double profitPips = 0.0;
            bool shouldClose = false;
            string closeReason = "";

            // ==========================================
            //  買いポジションの決済判定
            // ==========================================
            if(OrderType() == OP_BUY)
            {
               hasBuy = true;
               profitPips = (Bid - OrderOpenPrice()) / pUnit;
               
               int highIdx = iHighest(Symbol(), Period(), MODE_HIGH, barsToSearch, 0);
               double highestPrice = High[highIdx];
               
               // ストップラインの動的計算
               double initialSL  = OrderOpenPrice() - InpStopLoss * pUnit;
               double trailingSL = (InpTrailingStop > 0.0) ? (highestPrice - InpTrailingStop * pUnit) : 0.0;
               double currentSL  = (InpTrailingStop > 0.0) ? MathMax(initialSL, trailingSL) : initialSL;
               
               // 判定1：損切り（またはトレーリング）
               if(Bid <= currentSL) {
                  shouldClose = true;
                  closeReason = (currentSL == initialSL) ? "損切(スキャル)" : "ﾄﾚｰﾘﾝｸﾞ決済";
               }
               // 判定2：利食い（固定Pips）
               else if(InpTakeProfit > 0.0 && profitPips >= InpTakeProfit) {
                  shouldClose = true; closeReason = "利確(スキャル)";
               }
               // 判定3：停滞判定 (BB再収束)
               else if(isSqueezed && barsHeld >= InpWaitBars) {
                  shouldClose = true; closeReason = "停滞(BB再収束で撤退)";
               }

               if(shouldClose)
               {
                  bool res = OrderClose(OrderTicket(), OrderLots(), Bid, InpSlippage, clrWhite);
                  if(res) {
                     Print("【jaja スキャルEA】買い決済: ", closeReason, " / 損益: ", DoubleToString(profitPips, 1), " pips");
                     hasBuy = false;
                  }
               }
            }
            
            // ==========================================
            //  売りポジションの決済判定
            // ==========================================
            if(OrderType() == OP_SELL)
            {
               hasSell = true;
               profitPips = (OrderOpenPrice() - Ask) / pUnit;
               
               int lowIdx = iLowest(Symbol(), Period(), MODE_LOW, barsToSearch, 0);
               double lowestPrice = Low[lowIdx];

               // ストップラインの動的計算
               double initialSL  = OrderOpenPrice() + InpStopLoss * pUnit;
               double trailingSL = (InpTrailingStop > 0.0) ? (lowestPrice + InpTrailingStop * pUnit) : 99999.0;
               double currentSL  = (InpTrailingStop > 0.0) ? MathMin(initialSL, trailingSL) : initialSL;

               // 判定1：損切り（またはトレーリング）
               if(Ask >= currentSL) {
                  shouldClose = true;
                  closeReason = (currentSL == initialSL) ? "損切(スキャル)" : "ﾄﾚｰﾘﾝｸﾞ決済";
               }
               // 判定2：利食い（固定Pips）
               else if(InpTakeProfit > 0.0 && profitPips >= InpTakeProfit) {
                  shouldClose = true; closeReason = "利確(スキャル)";
               }
               // 判定3：停滞判定 (BB再収束)
               else if(isSqueezed && barsHeld >= InpWaitBars) {
                  shouldClose = true; closeReason = "停滞(BB再収束で撤退)";
               }

               if(shouldClose)
               {
                  bool res = OrderClose(OrderTicket(), OrderLots(), Ask, InpSlippage, clrWhite);
                  if(res) {
                     Print("【jaja スキャルEA】売り決済: ", closeReason, " / 損益: ", DoubleToString(profitPips, 1), " pips");
                     hasSell = false;
                  }
               }
            }
         }
      }
   }

   // 4. 新規エントリー処理 (同じ足での重複を防止)
   if(triggerBuy && !hasBuy && Time[0] != lastTradeBar)
   {
      int ticket = OrderSend(Symbol(), OP_BUY, InpLots, Ask, InpSlippage, 0, 0, "jaja Scalp Buy", InpMagic, 0, clrBlue);
      if(ticket > 0) {
         Print("【jaja スキャルEA】シグナル点灯(買い) エントリー完了");
         lastTradeBar = Time[0];
      }
   }
   
   if(triggerSell && !hasSell && Time[0] != lastTradeBar)
   {
      int ticket = OrderSend(Symbol(), OP_SELL, InpLots, Bid, InpSlippage, 0, 0, "jaja Scalp Sell", InpMagic, 0, clrRed);
      if(ticket > 0) {
         Print("【jaja スキャルEA】シグナル点灯(売り) エントリー完了");
         lastTradeBar = Time[0];
      }
   }
}