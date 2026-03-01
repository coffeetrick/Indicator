//+------------------------------------------------------------------+
//|                                              jaja_EA_Base.mq4    |
//|                                     Copyright 2026, Gemini Custom|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Gemini"
#property version   "1.10"
#property strict

// --- 入力パラメータ ---
input string Group_Entry = "--- エントリー設定 ---";
input double InpLots     = 0.01;      // エントリーロット数 (0.01 = 1,000通貨)
input int    InpSlippage = 30;        // 許容スリッページ (楽天MT4など5桁業者は30=3.0pips目安)
input int    InpMagic    = 20260301;  // マジックナンバー

input string Group_Exit  = "--- 勝ち逃げ決済(Exit)設定 ---";
input double InpStopLoss   = 10.0;    // 損切Pips (指定Pips逆行でカット)
input double InpTakeProfit = 10.0;    // 利確Pips (指定Pips巡行で勝ち逃げ)
input int    InpLimitBars  = 6;       // 停滞判定：最大保有ローソク足数 (M5なら6本=30分)
input double InpMinProfit  = 3.0;     // 停滞判定：上記時間を経過した際、このPips以下の利益なら決済

//+------------------------------------------------------------------+
//| ティック受信ごとのメイン処理                                     |
//+------------------------------------------------------------------+
void OnTick()
{
   double pUnit = (Digits == 3 || Digits == 5) ? Point * 10 : Point;

   // 1. jaja.mq4からシグナルを取得（ローソク足が確定した「1本前」の足を参照）
   double sigBuy  = iCustom(Symbol(), Period(), "jaja", 13, 1);
   double sigSell = iCustom(Symbol(), Period(), "jaja", 14, 1);

   bool isBuySignal  = (sigBuy != 0.0 && sigBuy != EMPTY_VALUE);
   bool isSellSignal = (sigSell != 0.0 && sigSell != EMPTY_VALUE);

   // 2. 現在の保有ポジションを確認と決済ロジック（勝ち逃げ判定）
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

            // --- 買いポジション保有中の場合 ---
            if(OrderType() == OP_BUY)
            {
               hasBuy = true;
               profitPips = (Bid - OrderOpenPrice()) / pUnit;

               // ① 損切り判定 (10Pips逆行)
               if(profitPips <= -InpStopLoss) {
                  shouldClose = true; closeReason = "損切(逆行)";
               }
               // ② 利食い判定 (勝ち逃げ)
               else if(profitPips >= InpTakeProfit) {
                  shouldClose = true; closeReason = "利確(勝ち逃げ)";
               }
               // ③ 停滞判定 (時間が経過し、かつ十分な利益が乗っていない)
               else if(barsHeld >= InpLimitBars && profitPips < InpMinProfit) {
                  shouldClose = true; closeReason = "停滞(時間切れ)";
               }

               if(shouldClose)
               {
                  bool res = OrderClose(OrderTicket(), OrderLots(), Bid, InpSlippage, clrWhite);
                  if(res) {
                     Print("【jaja EA】買い決済実行: ", closeReason, " / 損益: ", DoubleToString(profitPips, 1), " pips");
                     hasBuy = false;
                  }
               }
            }
            
            // --- 売りポジション保有中の場合 ---
            if(OrderType() == OP_SELL)
            {
               hasSell = true;
               profitPips = (OrderOpenPrice() - Ask) / pUnit;

               // ① 損切り判定
               if(profitPips <= -InpStopLoss) {
                  shouldClose = true; closeReason = "損切(逆行)";
               }
               // ② 利食い判定
               else if(profitPips >= InpTakeProfit) {
                  shouldClose = true; closeReason = "利確(勝ち逃げ)";
               }
               // ③ 停滞判定
               else if(barsHeld >= InpLimitBars && profitPips < InpMinProfit) {
                  shouldClose = true; closeReason = "停滞(時間切れ)";
               }

               if(shouldClose)
               {
                  bool res = OrderClose(OrderTicket(), OrderLots(), Ask, InpSlippage, clrWhite);
                  if(res) {
                     Print("【jaja EA】売り決済実行: ", closeReason, " / 損益: ", DoubleToString(profitPips, 1), " pips");
                     hasSell = false;
                  }
               }
            }
         }
      }
   }

   // 3. 新規エントリー処理 (ポジションを持っていない時だけエントリー)
   if(isBuySignal && !hasBuy)
   {
      int ticket = OrderSend(Symbol(), OP_BUY, InpLots, Ask, InpSlippage, 0, 0, "jaja Buy", InpMagic, 0, clrBlue);
      if(ticket > 0) Print("【jaja EA】★究極合致(買い) エントリー完了");
   }
   
   if(isSellSignal && !hasSell)
   {
      int ticket = OrderSend(Symbol(), OP_SELL, InpLots, Bid, InpSlippage, 0, 0, "jaja Sell", InpMagic, 0, clrRed);
      if(ticket > 0) Print("【jaja EA】★究極合致(売り) エントリー完了");
   }
}