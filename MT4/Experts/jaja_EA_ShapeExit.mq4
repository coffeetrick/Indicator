//+------------------------------------------------------------------+
//|                                        jaja_EA_ShapeExit.mq4     |
//|                                     Copyright 2026, Gemini Custom|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Gemini"
#property version   "3.00"
#property strict

// --- 入力パラメータ ---
input string Group_Entry = "--- エントリー設定 ---";
input double InpLots     = 0.10;      // エントリーロット数 (0.10 = 1万通貨)
input int    InpSlippage = 10;        // 許容スリッページ
input int    InpMagic    = 20260303;  // マジックナンバー

input string Group_Exit  = "--- 決済(Exit)設定 ---";
input double InpStopLoss      = 10.0; // 【絶対防衛線】指定Pips逆行で即座に損切り
input bool   InpHoldExpansion = true; // 【重要】サインが消えてもBBが拡大し続けている間はホールドする

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
   double sigM        = iCustom(Symbol(), Period(), "jaja",  6, 1); // M単体
   double sigB_Buy    = iCustom(Symbol(), Period(), "jaja",  8, 1); // B単体(買)
   double sigB_Sell   = iCustom(Symbol(), Period(), "jaja",  9, 1); // B単体(売)
   double sig1        = iCustom(Symbol(), Period(), "jaja", 10, 1); // ①収束+放たれ
   double sig2        = iCustom(Symbol(), Period(), "jaja", 11, 1); // ②収束+ホライゾン
   double sig3        = iCustom(Symbol(), Period(), "jaja", 12, 1); // ③ホライゾン+放たれ
   double sigStarBuy  = iCustom(Symbol(), Period(), "jaja", 13, 1); // ★究極合致(買)
   double sigStarSell = iCustom(Symbol(), Period(), "jaja", 14, 1); // ★究極合致(売)

   // --- エントリートリガー判定 (★ または ①) ---
   bool triggerBuy  = (sigStarBuy != 0.0 || (sig1 != 0.0 && sig1 < Close[1]));
   bool triggerSell = (sigStarSell != 0.0 || (sig1 != 0.0 && sig1 > Close[1]));

   // --- 決済用のサイン継続判定 ---
   // 「M(収束)」の要素を持つサインが1つでも点灯しているか？
   bool isM_Active = (sigM != 0.0 || sig1 != 0.0 || sig2 != 0.0 || sigStarBuy != 0.0 || sigStarSell != 0.0);
   // 「B(放たれ)」の要素を持つサインが1つでも点灯しているか？
   bool isB_Active = (sigB_Buy != 0.0 || sigB_Sell != 0.0 || sig1 != 0.0 || sig3 != 0.0 || sigStarBuy != 0.0 || sigStarSell != 0.0);
   
   // 「M」も「B」も両方とも消滅した状態
   bool no_M_and_B = (!isM_Active && !isB_Active);

   // ==========================================
   // 2. ボリンジャーバンドの「真の拡大」を判定
   // ==========================================
   double bbu1 = iBands(Symbol(), Period(), InpMA1, InpBBDev, 0, PRICE_CLOSE, MODE_UPPER, 1);
   double bbl1 = iBands(Symbol(), Period(), InpMA1, InpBBDev, 0, PRICE_CLOSE, MODE_LOWER, 1);
   double bbu2 = iBands(Symbol(), Period(), InpMA1, InpBBDev, 0, PRICE_CLOSE, MODE_UPPER, 2);
   double bbl2 = iBands(Symbol(), Period(), InpMA1, InpBBDev, 0, PRICE_CLOSE, MODE_LOWER, 2);
   
   double bw1 = (bbu1 - bbl1) / pUnit; // 1本前のバンド幅
   double bw2 = (bbu2 - bbl2) / pUnit; // 2本前のバンド幅
   
   // バンド幅が直前より広がっているか（トレンド継続中）
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
               
               // ① 絶対防衛線：10Pips逆行で即損切り（毎ティック判定）
               if(profitPips <= -InpStopLoss) {
                  shouldClose = true; closeReason = "10Pips逆行(損切)";
               }
               // ② サイン消滅決済：MもBもなくなり、かつバンドの拡大も止まったら利確・撤退
               else if(no_M_and_B) {
                  if(InpHoldExpansion && isBB_Expanding) {
                     // サインは無いがバンドが拡大中なのでホールド（何もしない）
                  } else {
                     shouldClose = true; closeReason = "M・Bサイン消滅";
                  }
               }

               if(shouldClose)
               {
                  bool res = OrderClose(OrderTicket(), OrderLots(), Bid, InpSlippage, clrWhite);
                  if(res) {
                     Print("【jaja 形状決済EA】買い決済: ", closeReason, " / 損益: ", DoubleToString(profitPips, 1), " pips");
                     hasBuy = false;
                  }
               }
            }
            
            if(OrderType() == OP_SELL)
            {
               hasSell = true;
               profitPips = (OrderOpenPrice() - Ask) / pUnit;
               
               // ① 絶対防衛線：10Pips逆行で即損切り
               if(profitPips <= -InpStopLoss) {
                  shouldClose = true; closeReason = "10Pips逆行(損切)";
               }
               // ② サイン消滅決済
               else if(no_M_and_B) {
                  if(InpHoldExpansion && isBB_Expanding) {
                     // サインは無いがバンドが拡大中なのでホールド
                  } else {
                     shouldClose = true; closeReason = "M・Bサイン消滅";
                  }
               }

               if(shouldClose)
               {
                  bool res = OrderClose(OrderTicket(), OrderLots(), Ask, InpSlippage, clrWhite);
                  if(res) {
                     Print("【jaja 形状決済EA】売り決済: ", closeReason, " / 損益: ", DoubleToString(profitPips, 1), " pips");
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
         Print("【jaja 形状決済EA】シグナル点灯(買い) エントリー完了");
         lastTradeBar = Time[0];
      }
   }
   
   if(triggerSell && !hasSell && Time[0] != lastTradeBar)
   {
      int ticket = OrderSend(Symbol(), OP_SELL, InpLots, Bid, InpSlippage, 0, 0, "jaja Sell", InpMagic, 0, clrRed);
      if(ticket > 0) {
         Print("【jaja 形状決済EA】シグナル点灯(売り) エントリー完了");
         lastTradeBar = Time[0];
      }
   }
}