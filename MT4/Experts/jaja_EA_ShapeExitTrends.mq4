//+------------------------------------------------------------------+
//|                                        jaja_EA_ShapeExit.mq4     |
//|                                     Copyright 2026, Gemini Custom|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Gemini"
#property version   "3.10"
#property strict

// --- 入力パラメータ ---
input string Group_Entry = "--- エントリー設定 ---";
input double InpLots     = 0.10;      // エントリーロット数
input int    InpSlippage = 10;        // 許容スリッページ
input int    InpMagic    = 20260303;  // マジックナンバー

input string Group_Filter = "--- トレンドフィルター設定 ---";
input bool   InpUseMAFilter = true;   // 長期MAフィルターを使用する
input int    InpFilterMA    = 200;    // フィルターのMA期間 (デフォルト: 200)

input string Group_Exit  = "--- 決済(Exit)設定 ---";
input double InpStopLoss      = 10.0; // 【絶対防衛線】指定Pips逆行で即座に損切り
input bool   InpHoldExpansion = true; // サインが消えてもBBが拡大し続けている間はホールドする

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

   // ==========================================
   // 1. jaja.mq4から全シグナルを取得（1本前の確定足）
   // ==========================================
   double sigM        = iCustom(Symbol(), Period(), "jaja",  6, 1);
   double sigB_Buy    = iCustom(Symbol(), Period(), "jaja",  8, 1);
   double sigB_Sell   = iCustom(Symbol(), Period(), "jaja",  9, 1);
   double sig1        = iCustom(Symbol(), Period(), "jaja", 10, 1);
   double sig2        = iCustom(Symbol(), Period(), "jaja", 11, 1);
   double sig3        = iCustom(Symbol(), Period(), "jaja", 12, 1);
   double sigStarBuy  = iCustom(Symbol(), Period(), "jaja", 13, 1);
   double sigStarSell = iCustom(Symbol(), Period(), "jaja", 14, 1);

   // --- 基本のエントリートリガー判定 (★ または ①) ---
   bool triggerBuy  = (sigStarBuy != 0.0 || (sig1 != 0.0 && sig1 < Close[1]));
   bool triggerSell = (sigStarSell != 0.0 || (sig1 != 0.0 && sig1 > Close[1]));

   // --- 【新規】長期MAフィルターの判定 ---
   if(InpUseMAFilter) {
      // 1本前の確定足におけるMA200の値を計算
      double maFilter = iMA(Symbol(), Period(), InpFilterMA, 0, MODE_SMA, PRICE_CLOSE, 1);
      
      // ローソク足(終値)がMA200より上なら「上昇トレンド」、下なら「下降トレンド」
      bool isTrendUp   = (Close[1] > maFilter);
      bool isTrendDown = (Close[1] < maFilter);
      
      // トレンドと一致しないシグナルを無効化（ダマシを弾く）
      triggerBuy  = (triggerBuy && isTrendUp);
      triggerSell = (triggerSell && isTrendDown);
   }

   // --- 決済用のサイン継続判定 ---
   bool isM_Active = (sigM != 0.0 || sig1 != 0.0 || sig2 != 0.0 || sigStarBuy != 0.0 || sigStarSell != 0.0);
   bool isB_Active = (sigB_Buy != 0.0 || sigB_Sell != 0.0 || sig1 != 0.0 || sig3 != 0.0 || sigStarBuy != 0.0 || sigStarSell != 0.0);
   bool no_M_and_B = (!isM_Active && !isB_Active);

   // ==========================================
   // 2. ボリンジャーバンドの「真の拡大」を判定
   // ==========================================
   double bbu1 = iBands(Symbol(), Period(), InpMA1, InpBBDev, 0, PRICE_CLOSE, MODE_UPPER, 1);
   double bbl1 = iBands(Symbol(), Period(), InpMA1, InpBBDev, 0, PRICE_CLOSE, MODE_LOWER, 1);
   double bbu2 = iBands(Symbol(), Period(), InpMA1, InpBBDev, 0, PRICE_CLOSE, MODE_UPPER, 2);
   double bbl2 = iBands(Symbol(), Period(), InpMA1, InpBBDev, 0, PRICE_CLOSE, MODE_LOWER, 2);
   
   double bw1 = (bbu1 - bbl1) / pUnit;
   double bw2 = (bbu2 - bbl2) / pUnit;
   bool isBB_Expanding = (bw1 > bw2);

   // ==========================================
   // 3. ポジションの決済ロジック
   // ==========================================
   int totalOrders = OrdersTotal();
   bool hasBuy = false;
   bool hasSell = false;

   for(int i = totalOrders - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == InpMagic)
         {
            double profitPips = 0.0;
            bool shouldClose = false;
            string closeReason = "";

            if(OrderType() == OP_BUY)
            {
               hasBuy = true;
               profitPips = (Bid - OrderOpenPrice()) / pUnit;
               
               if(profitPips <= -InpStopLoss) {
                  shouldClose = true; closeReason = "10Pips逆行(損切)";
               }
               else if(no_M_and_B) {
                  if(InpHoldExpansion && isBB_Expanding) {
                     // ホールド
                  } else {
                     shouldClose = true; closeReason = "M・Bサイン消滅";
                  }
               }

               if(shouldClose)
               {
                  bool res = OrderClose(OrderTicket(), OrderLots(), Bid, InpSlippage, clrWhite);
                  if(res) {
                     Print("【jaja EA】買い決済: ", closeReason, " / 損益: ", DoubleToString(profitPips, 1), " pips");
                     hasBuy = false;
                  }
               }
            }
            
            if(OrderType() == OP_SELL)
            {
               hasSell = true;
               profitPips = (OrderOpenPrice() - Ask) / pUnit;
               
               if(profitPips <= -InpStopLoss) {
                  shouldClose = true; closeReason = "10Pips逆行(損切)";
               }
               else if(no_M_and_B) {
                  if(InpHoldExpansion && isBB_Expanding) {
                     // ホールド
                  } else {
                     shouldClose = true; closeReason = "M・Bサイン消滅";
                  }
               }

               if(shouldClose)
               {
                  bool res = OrderClose(OrderTicket(), OrderLots(), Ask, InpSlippage, clrWhite);
                  if(res) {
                     Print("【jaja EA】売り決済: ", closeReason, " / 損益: ", DoubleToString(profitPips, 1), " pips");
                     hasSell = false;
                  }
               }
            }
         }
      }
   }

   // ==========================================
   // 4. 新規エントリー処理
   // ==========================================
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