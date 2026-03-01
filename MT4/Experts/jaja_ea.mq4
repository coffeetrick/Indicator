//+------------------------------------------------------------------+
//|                                              jaja_EA_Base.mq4    |
//|                                     Copyright 2026, Gemini Custom|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Gemini"
#property version   "1.30"
#property strict

// --- 入力パラメータ ---
input string Group_Entry = "--- エントリー設定 ---";
input double InpLots     = 0.01;      // エントリーロット数 (0.01 = 1,000通貨)
input int    InpSlippage = 30;        // 許容スリッページ (楽天MT4など5桁業者は30=3.0pips目安)
input int    InpMagic    = 20260301;  // マジックナンバー

input string Group_Exit  = "--- 勝ち逃げ決済(Exit)設定 ---";
input double InpStopLoss   = 10.0;    // 損切Pips (指定Pips逆行でカット)
input double InpTakeProfit = 10.0;    // 利確Pips (指定Pips巡行で勝ち逃げ)

input string Group_BBExit  = "--- 停滞判定(BB再収束)設定 ---";
input double InpCloseSqzPips = 5.0;   // 【修正】BB幅がこのPips以下なら「完全に相場が死んだ」とみなす
input int    InpWaitBars     = 1;     // 【新規】エントリー後、最低何本(5分)は決済を我慢するか

input string Group_BB    = "--- インジケーター連動BB設定 ---";
input int    InpMA1      = 5;         // BB期間
input double InpBBDev    = 2.0;       // BB偏差

// 【新規】連続エントリー防止用の記録変数
datetime lastTradeBar = 0;

//+------------------------------------------------------------------+
//| ティック受信ごとのメイン処理                                     |
//+------------------------------------------------------------------+
void OnTick()
{
   double pUnit = (Digits == 3 || Digits == 5) ? Point * 10 : Point;

   // 1. jaja.mq4からシグナルを取得（ローソク足が確定した「1本前」の足）
   double sigBuy  = iCustom(Symbol(), Period(), "jaja", 13, 1);
   double sigSell = iCustom(Symbol(), Period(), "jaja", 14, 1);

   bool isBuySignal  = (sigBuy != 0.0 && sigBuy != EMPTY_VALUE);
   bool isSellSignal = (sigSell != 0.0 && sigSell != EMPTY_VALUE);

   // 2. 現在のボリンジャーバンド幅を計算
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
            double profitPips = 0.0;
            bool shouldClose = false;
            string closeReason = "";

            if(OrderType() == OP_BUY)
            {
               hasBuy = true;
               profitPips = (Bid - OrderOpenPrice()) / pUnit;

               if(profitPips <= -InpStopLoss) {
                  shouldClose = true; closeReason = "損切(逆行)";
               }
               else if(profitPips >= InpTakeProfit) {
                  shouldClose = true; closeReason = "利確(勝ち逃げ)";
               }
               // 【修正】エントリー直後の即決済を防ぐため、InpWaitBars(1本=5分)以上経過を必須条件に
               else if(isSqueezed && barsHeld >= InpWaitBars) {
                  shouldClose = true; closeReason = "停滞(BB再収束)";
               }

               if(shouldClose)
               {
                  bool res = OrderClose(OrderTicket(), OrderLots(), Bid, InpSlippage, clrWhite);
                  if(res) {
                     Print("【jaja EA】買い決済実行: ", closeReason, " / 損益: ", DoubleToString(profitPips, 1), " pips / BB幅: ", DoubleToString(currentBW, 1));
                     hasBuy = false;
                  }
               }
            }
            
            if(OrderType() == OP_SELL)
            {
               hasSell = true;
               profitPips = (OrderOpenPrice() - Ask) / pUnit;

               if(profitPips <= -InpStopLoss) {
                  shouldClose = true; closeReason = "損切(逆行)";
               }
               else if(profitPips >= InpTakeProfit) {
                  shouldClose = true; closeReason = "利確(勝ち逃げ)";
               }
               else if(isSqueezed && barsHeld >= InpWaitBars) {
                  shouldClose = true; closeReason = "停滞(BB再収束)";
               }

               if(shouldClose)
               {
                  bool res = OrderClose(OrderTicket(), OrderLots(), Ask, InpSlippage, clrWhite);
                  if(res) {
                     Print("【jaja EA】売り決済実行: ", closeReason, " / 損益: ", DoubleToString(profitPips, 1), " pips / BB幅: ", DoubleToString(currentBW, 1));
                     hasSell = false;
                  }
               }
            }
         }
      }
   }

   // 4. 新規エントリー処理
   // 【修正】Time[0] != lastTradeBar により、同じローソク足での重複エントリーを完全ブロック
   if(isBuySignal && !hasBuy && Time[0] != lastTradeBar)
   {
      int ticket = OrderSend(Symbol(), OP_BUY, InpLots, Ask, InpSlippage, 0, 0, "jaja Buy", InpMagic, 0, clrBlue);
      if(ticket > 0) {
         Print("【jaja EA】★究極合致(買い) エントリー完了");
         lastTradeBar = Time[0]; // エントリーした足の時間を記録
      }
   }
   
   if(isSellSignal && !hasSell && Time[0] != lastTradeBar)
   {
      int ticket = OrderSend(Symbol(), OP_SELL, InpLots, Bid, InpSlippage, 0, 0, "jaja Sell", InpMagic, 0, clrRed);
      if(ticket > 0) {
         Print("【jaja EA】★究極合致(売り) エントリー完了");
         lastTradeBar = Time[0]; // エントリーした足の時間を記録
      }
   }
}