//+------------------------------------------------------------------+
//|                                              jaja_EA_Base.mq4    |
//|                                     Copyright 2026, Gemini Custom|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Gemini"
#property version   "1.00"
#property strict

// --- 入力パラメータ ---
input double InpLots     = 0.01;      // エントリーロット数 (0.01 = 1,000通貨)
input int    InpSlippage = 30;        // 許容スリッページ (楽天MT4など5桁業者は30=3.0pips目安)
input int    InpMagic    = 20260301;  // マジックナンバー (EAが自分の注文を識別するためのID)

//+------------------------------------------------------------------+
//| ティック受信ごとのメイン処理                                     |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. jaja.mq4からシグナルを取得（ローソク足が確定した「1本前」の足を参照）
   // 第4引数の 13 は「★買い」、14 は「★売り」。第5引数の 1 は「1本前の足」を意味します。
   double sigBuy  = iCustom(Symbol(), Period(), "jaja", 13, 1);
   double sigSell = iCustom(Symbol(), Period(), "jaja", 14, 1);

   // シグナルが0.0やEMPTY_VALUEでなければ「サイン点灯」と判定
   bool isBuySignal  = (sigBuy != 0.0 && sigBuy != EMPTY_VALUE);
   bool isSellSignal = (sigSell != 0.0 && sigSell != EMPTY_VALUE);

   // 2. 現在の保有ポジションを確認
   int totalOrders = OrdersTotal();
   bool hasBuy = false;
   bool hasSell = false;

   // 古い注文から最新の注文までループで確認
   for(int i = totalOrders - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         // このEAが出した、現在の通貨ペアの注文だけを対象とする
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == InpMagic)
         {
            // --- 買いポジション保有中の場合 ---
            if(OrderType() == OP_BUY)
            {
               if(isSellSignal) // 逆のサイン（売り★）が出たら決済
               {
                  bool res = OrderClose(OrderTicket(), OrderLots(), Bid, InpSlippage, clrWhite);
                  if(res) Print("【jaja EA】逆サイン点灯のため、買いポジションを決済しました。");
               }
               else
               {
                  hasBuy = true; // まだ決済されていなければ保有中フラグを立てる
               }
            }
            
            // --- 売りポジション保有中の場合 ---
            if(OrderType() == OP_SELL)
            {
               if(isBuySignal) // 逆のサイン（買い★）が出たら決済
               {
                  bool res = OrderClose(OrderTicket(), OrderLots(), Ask, InpSlippage, clrWhite);
                  if(res) Print("【jaja EA】逆サイン点灯のため、売りポジションを決済しました。");
               }
               else
               {
                  hasSell = true; // まだ決済されていなければ保有中フラグを立てる
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