//+------------------------------------------------------------------+
//|                                        jaja_EA_ShapeExit.mq4     |
//|                                     Copyright 2026, Gemini Custom|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Gemini"
#property version   "4.00" // 建値ストップ＆トレーリング搭載版
#property strict

// --- 入力パラメータ ---
input string Group_Entry = "--- エントリー設定 ---";
input double InpLots     = 0.10;      // エントリーロット数
input int    InpSlippage = 10;        // 許容スリッページ
input int    InpMagic    = 20260303;  // マジックナンバー

input string Group_Filter = "--- トレンドフィルター設定 ---";
input bool   InpUseMAFilter = true;   // 長期MAフィルターを使用する(falseで無効化)
input int    InpFilterMA    = 200;    // フィルターのMA期間

input string Group_Exit  = "--- 決済(Exit)設定 ---";
input double InpStopLoss      = 10.0; // ①初期損切Pips (指定Pips逆行で即損切り)
input bool   InpHoldExpansion = true; // ②BB拡大中はM・Bサインが消えてもホールドする

input string Group_Trail = "--- 建値・トレーリング設定 ---";
input double InpBreakEvenTrigger = 10.0; // 【建値】含み益がこのPipsに達したらSLを建値に移動
input double InpBreakEvenOffset  =  0.5; // 【建値】建値から何Pipsプラスの位置にSLを置くか(微益撤退用)
input double InpTrailingStart    = 15.0; // 【ﾄﾚｰﾙ】含み益がこのPipsに達したらトレーリング開始
input double InpTrailingStep     = 10.0; // 【ﾄﾚｰﾙ】最高値/最安値から何Pips逆行で決済するか

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

   // 1. jaja.mq4から全シグナルを取得（1本前の確定足）
   double sigM        = iCustom(Symbol(), Period(), "jaja",  6, 1);
   double sigB_Buy    = iCustom(Symbol(), Period(), "jaja",  8, 1);
   double sigB_Sell   = iCustom(Symbol(), Period(), "jaja",  9, 1);
   double sig1        = iCustom(Symbol(), Period(), "jaja", 10, 1);
   double sig2        = iCustom(Symbol(), Period(), "jaja", 11, 1);
   double sig3        = iCustom(Symbol(), Period(), "jaja", 12, 1);
   double sigStarBuy  = iCustom(Symbol(), Period(), "jaja", 13, 1);
   double sigStarSell = iCustom(Symbol(), Period(), "jaja", 14, 1);

   // --- 基本のエントリートリガー判定 ---
   bool triggerBuy  = (sigStarBuy != 0.0 || (sig1 != 0.0 && sig1 < Close[1]));
   bool triggerSell = (sigStarSell != 0.0 || (sig1 != 0.0 && sig1 > Close[1]));

   // --- 長期MAフィルターの判定 ---
   if(InpUseMAFilter) {
      double maFilter = iMA(Symbol(), Period(), InpFilterMA, 0, MODE_SMA, PRICE_CLOSE, 1);
      bool isTrendUp   = (Close[1] > maFilter);
      bool isTrendDown = (Close[1] < maFilter);
      triggerBuy  = (triggerBuy && isTrendUp);
      triggerSell = (triggerSell && isTrendDown);
   }

   // --- 決済用のサイン継続判定 ---
   bool isM_Active = (sigM != 0.0 || sig1 != 0.0 || sig2 != 0.0 || sigStarBuy != 0.0 || sigStarSell != 0.0);
   bool isB_Active = (sigB_Buy != 0.0 || sigB_Sell != 0.0 || sig1 != 0.0 || sig3 != 0.0 || sigStarBuy != 0.0 || sigStarSell != 0.0);
   bool no_M_and_B = (!isM_Active && !isB_Active);

   // 2. ボリンジャーバンドの「真の拡大」を判定
   double bbu1 = iBands(Symbol(), Period(), InpMA1, InpBBDev, 0, PRICE_CLOSE, MODE_UPPER, 1);
   double bbl1 = iBands(Symbol(), Period(), InpMA1, InpBBDev, 0, PRICE_CLOSE, MODE_LOWER, 1);
   double bbu2 = iBands(Symbol(), Period(), InpMA1, InpBBDev, 0, PRICE_CLOSE, MODE_UPPER, 2);
   double bbl2 = iBands(Symbol(), Period(), InpMA1, InpBBDev, 0, PRICE_CLOSE, MODE_LOWER, 2);
   
   double bw1 = (bbu1 - bbl1) / pUnit;
   double bw2 = (bbu2 - bbl2) / pUnit;
   bool isBB_Expanding = (bw1 > bw2);

   // 3. ポジションの決済ロジック
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

            if(OrderType() == OP_BUY)
            {
               hasBuy = true;
               profitPips = (Bid - OrderOpenPrice()) / pUnit;
               
               // エントリー以降の「最高値」を取得
               int highIdx = iHighest(Symbol(), Period(), MODE_HIGH, barsToSearch, 0);
               double maxPrice = High[highIdx];
               double maxPips  = (maxPrice - OrderOpenPrice()) / pUnit;
               
               // --- ストップラインの動的計算 ---
               // ① 初期損切りライン (-10Pips)
               double currentSL = OrderOpenPrice() - InpStopLoss * pUnit;
               
               // ② 建値ストップライン (最大含み益が指定に達したら、建値+微益へ移動)
               if(maxPips >= InpBreakEvenTrigger) {
                  currentSL = MathMax(currentSL, OrderOpenPrice() + InpBreakEvenOffset * pUnit);
               }
               
               // ③ トレーリングストップライン (最大含み益が指定に達したら、最高値から追従)
               if(maxPips >= InpTrailingStart) {
                  currentSL = MathMax(currentSL, maxPrice - InpTrailingStep * pUnit);
               }

               // 判定1：価格がストップライン(初期/建値/ﾄﾚｰﾙ)を割ったか？
               if(Bid <= currentSL) {
                  shouldClose = true;
                  if(currentSL > OrderOpenPrice()) closeReason = "建値/ﾄﾚｰﾙ決済";
                  else closeReason = "初期損切";
               }
               // 判定2：サイン消滅による形状決済
               else if(no_M_and_B) {
                  if(!InpHoldExpansion || !isBB_Expanding) {
                     shouldClose = true; closeReason = "M・Bサイン消滅";
                  }
               }

               if(shouldClose)
               {
                  bool res = OrderClose(OrderTicket(), OrderLots(), Bid, InpSlippage, clrWhite);
                  if(res) {
                     PrintFormat("【jaja EA】買い決済: %s | 最終損益: %.1f pips (最大含み益: %.1f pips)", closeReason, profitPips, maxPips);
                     hasBuy = false;
                  }
               }
            }
            
            if(OrderType() == OP_SELL)
            {
               hasSell = true;
               profitPips = (OrderOpenPrice() - Ask) / pUnit;
               
               // エントリー以降の「最安値」を取得
               int lowIdx = iLowest(Symbol(), Period(), MODE_LOW, barsToSearch, 0);
               double minPrice = Low[lowIdx];
               double maxPips  = (OrderOpenPrice() - minPrice) / pUnit;

               // --- ストップラインの動的計算 ---
               // ① 初期損切りライン (+10Pips)
               double currentSL = OrderOpenPrice() + InpStopLoss * pUnit;
               
               // ② 建値ストップライン (最大含み益が指定に達したら、建値-微益へ移動)
               if(maxPips >= InpBreakEvenTrigger) {
                  currentSL = MathMin(currentSL, OrderOpenPrice() - InpBreakEvenOffset * pUnit);
               }
               
               // ③ トレーリングストップライン
               if(maxPips >= InpTrailingStart) {
                  currentSL = MathMin(currentSL, minPrice + InpTrailingStep * pUnit);
               }

               // 判定1：価格がストップラインを上抜けたか？
               if(Ask >= currentSL) {
                  shouldClose = true;
                  if(currentSL < OrderOpenPrice()) closeReason = "建値/ﾄﾚｰﾙ決済";
                  else closeReason = "初期損切";
               }
               // 判定2：サイン消滅による形状決済
               else if(no_M_and_B) {
                  if(!InpHoldExpansion || !isBB_Expanding) {
                     shouldClose = true; closeReason = "M・Bサイン消滅";
                  }
               }

               if(shouldClose)
               {
                  bool res = OrderClose(OrderTicket(), OrderLots(), Ask, InpSlippage, clrWhite);
                  if(res) {
                     PrintFormat("【jaja EA】売り決済: %s | 最終損益: %.1f pips (最大含み益: %.1f pips)", closeReason, profitPips, maxPips);
                     hasSell = false;
                  }
               }
            }
         }
      }
   }

   // 4. 新規エントリー処理
   if(triggerBuy && !hasBuy && Time[0] != lastTradeBar)
   {
      int ticket = OrderSend(Symbol(), OP_BUY, InpLots, Ask, InpSlippage, 0, 0, "jaja Buy", InpMagic, 0, clrBlue);
      if(ticket > 0) {
         Print("【jaja EA】シグナル点灯(買い) エントリー完了");
         lastTradeBar = Time[0];
      }
   }
   
   if(triggerSell && !hasSell && Time[0] != lastTradeBar)
   {
      int ticket = OrderSend(Symbol(), OP_SELL, InpLots, Bid, InpSlippage, 0, 0, "jaja Sell", InpMagic, 0, clrRed);
      if(ticket > 0) {
         Print("【jaja EA】シグナル点灯(売り) エントリー完了");
         lastTradeBar = Time[0];
      }
   }
}