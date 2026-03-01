//+------------------------------------------------------------------+
//|                                     jaja.mq4                     |
//|                                  Copyright 2026, Gemini Custom   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Gemini"
#property indicator_chart_window
// ★修正：BB上・下のバッファを含め17個に変更
#property indicator_buffers 17 

// --- インデックス定義
#define BUF_M 6
#define BUF_H 7
#define BUF_B_B 8
#define BUF_B_S 9
#define BUF_1 10
#define BUF_2 11
#define BUF_3 12
#define BUF_T_B 13
#define BUF_T_S 14
#define BUF_BBU 15 // BB Upper
#define BUF_BBL 16 // BB Lower

// --- 色とスタイルの設定
#property indicator_color1 clrWhite   
#property indicator_color2 clrYellow  
#property indicator_color3 clrOrange  
#property indicator_color4 clrGreen   
#property indicator_color5 clrBlue    
#property indicator_color6 clrFuchsia 

#property indicator_color7 clrAqua     
#property indicator_color8 clrYellow   
#property indicator_color9 clrLime     
#property indicator_color10 clrRed     
#property indicator_color11 clrAqua    
#property indicator_color12 clrAqua    
#property indicator_color13 clrYellow  
#property indicator_color14 clrGold    
#property indicator_color15 clrMagenta 
#property indicator_color16 clrAqua    // BB Upper
#property indicator_color17 clrAqua    // BB Lower

// --- 入力パラメータ ---
input string Group_MA = "--- 移動平均線設定 ---";
input int InpMA1=5, InpMA2=10, InpMA3=25, InpMA4=90, InpMA5=120, InpMA6=200;

input string Group_Logic = "--- ロジック閾値設定 ---";
input double InpConvPips=10.0;     
input int    InpConvCnt=3;        
input double InpHorzPips=3.0;      
input int    InpHorzBars=3;       
input int    InpHorzMemory=5;     
input double InpBBDev=2.0;         
input double InpSqzPips=30.0;     
input double InpExpPips=1.0;      
input double InpAngLimit=0.1;     

input string Group_Visual = "--- 表示設定 ---";
input int    InpSigSize=4;        

// --- 通知・アラート設定 ---
input string Group_Alert = "--- 通知・アラート設定 ---";
input bool InpAlertEnable = true;       // アラート機能を有効にする
input bool InpAlertPopup  = true;       // MT4画面のポップアップと音
input bool InpAlertPush   = true;       // スマホへのプッシュ通知
input bool InpAlertTripleOnly = false;  // ★(究極合致)の時のみ通知する

// 通知スパム防止用の時間記録変数
datetime lastAlertTime_T_B = 0;
datetime lastAlertTime_T_S = 0;
datetime lastAlertTime_1   = 0;
datetime lastAlertTime_2   = 0;
datetime lastAlertTime_3   = 0;

// --- バッファ配列 ---
double bMA1[], bMA2[], bMA3[], bMA4[], bMA5[], bMA6[];
double bM[], bH[], bB_B[], bB_S[], b1[], b2[], b3[], bT_B[], bT_S[];
double bBBU[], bBBL[]; // BB用追加

int OnInit() {
   IndicatorBuffers(17);
   
   SetIndexBuffer(0,bMA1); SetIndexStyle(0,DRAW_LINE);
   SetIndexBuffer(1,bMA2); SetIndexStyle(1,DRAW_LINE);
   SetIndexBuffer(2,bMA3); SetIndexStyle(2,DRAW_LINE);
   SetIndexBuffer(3,bMA4); SetIndexStyle(3,DRAW_LINE);
   SetIndexBuffer(4,bMA5); SetIndexStyle(4,DRAW_LINE);
   SetIndexBuffer(5,bMA6); SetIndexStyle(5,DRAW_LINE);

   SetIndexBuffer(BUF_M,bM);      SetIndexStyle(BUF_M, DRAW_ARROW, EMPTY, 2); SetIndexArrow(BUF_M,77);
   SetIndexBuffer(BUF_H,bH);      SetIndexStyle(BUF_H, DRAW_ARROW, EMPTY, 2); SetIndexArrow(BUF_H,72);
   SetIndexBuffer(BUF_B_B,bB_B);  SetIndexStyle(BUF_B_B, DRAW_ARROW, EMPTY, 2); SetIndexArrow(BUF_B_B,66);
   SetIndexBuffer(BUF_B_S,bB_S);  SetIndexStyle(BUF_B_S, DRAW_ARROW, EMPTY, 2); SetIndexArrow(BUF_B_S,66);
   
   SetIndexBuffer(BUF_1,b1);      SetIndexStyle(BUF_1, DRAW_ARROW, EMPTY, InpSigSize); SetIndexArrow(BUF_1,129);
   SetIndexBuffer(BUF_2,b2);      SetIndexStyle(BUF_2, DRAW_ARROW, EMPTY, InpSigSize); SetIndexArrow(BUF_2,130);
   SetIndexBuffer(BUF_3,b3);      SetIndexStyle(BUF_3, DRAW_ARROW, EMPTY, InpSigSize); SetIndexArrow(BUF_3,131);
   
   SetIndexBuffer(BUF_T_B,bT_B);  SetIndexStyle(BUF_T_B, DRAW_ARROW, EMPTY, InpSigSize+1); SetIndexArrow(BUF_T_B,171);
   SetIndexBuffer(BUF_T_S,bT_S);  SetIndexStyle(BUF_T_S, DRAW_ARROW, EMPTY, InpSigSize+1); SetIndexArrow(BUF_T_S,171);

   // ★復活：ボリンジャーバンドの描画
   SetIndexBuffer(BUF_BBU,bBBU);  SetIndexStyle(BUF_BBU, DRAW_LINE, STYLE_SOLID, 2);
   SetIndexBuffer(BUF_BBL,bBBL);  SetIndexStyle(BUF_BBL, DRAW_LINE, STYLE_SOLID, 2);
   
   for(int i=BUF_M; i<=BUF_BBL; i++) SetIndexEmptyValue(i, 0.0);
   
   return(INIT_SUCCEEDED);
}

int OnCalculate(const int rates_total,const int prev_calculated,const datetime &time[],
                const double &open[],const double &high[],const double &low[],const double &close[],
                const long &tick_volume[],const long &volume[],const int &spread[])
{
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(time, true);

   int limit = rates_total - prev_calculated;
   if(limit <= 0) limit = 1;
   if(prev_calculated == 0) limit = rates_total - 201;

   double pUnit = (Digits==3 || Digits==5) ? Point*10 : Point;

   for(int i=limit; i>=0; i--) {
      bMA1[i]=iMA(NULL,0,InpMA1,0,MODE_SMA,PRICE_CLOSE,i);
      bMA2[i]=iMA(NULL,0,InpMA2,0,MODE_SMA,PRICE_CLOSE,i);
      bMA3[i]=iMA(NULL,0,InpMA3,0,MODE_SMA,PRICE_CLOSE,i);
      bMA4[i]=iMA(NULL,0,InpMA4,0,MODE_SMA,PRICE_CLOSE,i);
      bMA5[i]=iMA(NULL,0,InpMA5,0,MODE_SMA,PRICE_CLOSE,i);
      bMA6[i]=iMA(NULL,0,InpMA6,0,MODE_SMA,PRICE_CLOSE,i);

      bM[i]=bH[i]=bB_B[i]=bB_S[i]=b1[i]=b2[i]=b3[i]=bT_B[i]=bT_S[i]=0.0;

      // --- [1] M判定 ---
      bool cM=false; double v[6]; v[0]=bMA1[i]; v[1]=bMA2[i]; v[2]=bMA3[i]; v[3]=bMA4[i]; v[4]=bMA5[i]; v[5]=bMA6[i];
      for(int m=0; m<6; m++){ 
         int cnt=0; 
         for(int n=0; n<6; n++){ 
            if(MathAbs(v[m]-v[n])/pUnit <= InpConvPips) cnt++; 
         } 
         if(cnt>=InpConvCnt){ cM=true; break; } 
      }

      // --- [2] H判定 ---
      bool cH=false;
      for(int k=0; k<InpHorzMemory; k++) {
         bool ok=true; 
         for(int j=0; j<InpHorzBars; j++) { 
            if(MathAbs(open[i+k+j]-close[i+k+j])/pUnit > InpHorzPips) ok=false; 
         }
         if(ok){ cH=true; break; }
      }

      // --- [3] B判定 & BB描画 ---
      double bbu=iBands(NULL,0,InpMA1,InpBBDev,0,PRICE_CLOSE,MODE_UPPER,i);
      double bbl=iBands(NULL,0,InpMA1,InpBBDev,0,PRICE_CLOSE,MODE_LOWER,i);
      
      // ★復活：BBをチャートに描画
      bBBU[i] = bbu;
      bBBL[i] = bbl;
      
      double pbbu=iBands(NULL,0,InpMA1,InpBBDev,0,PRICE_CLOSE,MODE_UPPER,i+1);
      double pbbl=iBands(NULL,0,InpMA1,InpBBDev,0,PRICE_CLOSE,MODE_LOWER,i+1);
      
      double bw=(bbu-bbl)/pUnit, pbw=(pbbu-pbbl)/pUnit;
      double ang=(bMA1[i]-iMA(NULL,0,InpMA1,0,MODE_SMA,PRICE_CLOSE,i+1))/pUnit;
      
      bool bBuy = (pbw < InpSqzPips && (bw-pbw) >= InpExpPips && ang > InpAngLimit);
      bool bSell = (pbw < InpSqzPips && (bw-pbw) >= InpExpPips && ang < -InpAngLimit);
      bool cB = (bBuy || bSell);

      // --- [4] 排他的プロット ---
      if(cM && cH && cB) { 
         if(bBuy) bT_B[i]=low[i]-20*pUnit; else bT_S[i]=high[i]+20*pUnit;
      } else if(cM && cB) { 
         b1[i] = bBuy ? low[i]-15*pUnit : high[i]+15*pUnit;
      } else if(cM && cH) { 
         b2[i] = low[i]-10*pUnit;
      } else if(cB && cH) { 
         b3[i] = bBuy ? low[i]-15*pUnit : high[i]+15*pUnit;
      } else {
         if(cM) bM[i] = low[i]-5*pUnit;
         if(cH) bH[i] = high[i]+5*pUnit;
         if(bBuy) bB_B[i] = low[i]-15*pUnit;
         if(bSell) bB_S[i] = high[i]+15*pUnit;
      }

      // --- [5] アラート・通知処理 ---
      if(InpAlertEnable && i == 0) {
         string symbol = Symbol();
         string tf = EnumToString((ENUM_TIMEFRAMES)Period());
         string msg = "";

         if(cM && cH && cB) { 
            if(bBuy && time[0] != lastAlertTime_T_B) {
               msg = "【jaja】" + symbol + " (" + tf + ") ★究極合致(買い)発生！";
               lastAlertTime_T_B = time[0];
            } else if(bSell && time[0] != lastAlertTime_T_S) {
               msg = "【jaja】" + symbol + " (" + tf + ") ★究極合致(売り)発生！";
               lastAlertTime_T_S = time[0];
            }
         } 
         else if(!InpAlertTripleOnly) { 
            if(cM && cB && time[0] != lastAlertTime_1) {
               msg = "【jaja】" + symbol + " (" + tf + ") ①収束+放たれ！";
               lastAlertTime_1 = time[0];
            } else if(cM && cH && time[0] != lastAlertTime_2) {
               msg = "【jaja】" + symbol + " (" + tf + ") ②収束+ホライゾン(パワー蓄積中)";
               lastAlertTime_2 = time[0];
            } else if(cB && cH && time[0] != lastAlertTime_3) {
               msg = "【jaja】" + symbol + " (" + tf + ") ③ホライゾン+放たれ(初動)";
               lastAlertTime_3 = time[0];
            }
         }

         if(msg != "") {
            if(InpAlertPopup) Alert(msg);
            if(InpAlertPush) SendNotification(msg);
         }
      }
   }
   return(rates_total);
}