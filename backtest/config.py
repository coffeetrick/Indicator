"""
バックテスト自動化システム - 設定ファイル
環境に合わせてここの値を変更してください。
"""
from pathlib import Path

# ============================================================
# MT4 パス設定
# ============================================================
MT4_EXE = r"C:\Program Files (x86)\FXTF MT4\terminal.exe"

# MT4 データディレクトリ (AppData 内)
MT4_DATA_DIR = Path(r"C:\Users\ruri_\AppData\Roaming\MetaQuotes\Terminal\A84B568DA10F82FE5A8FF6A859153D6F")

MT4_EXPERTS_DIR  = MT4_DATA_DIR / "MQL4" / "Experts"
MT4_TESTER_DIR   = MT4_DATA_DIR / "tester"
MT4_TESTER_FILES = MT4_DATA_DIR / "tester" / "files"

# ============================================================
# EA 設定
# ============================================================
EA_NAME = "jaja_EA_v5"

# EA ソースファイル (リポジトリ内)
EA_SOURCE = Path(r"C:\dev\claude\Indicator\MT4\Experts\jaja_EA_v5.mq4")

# ============================================================
# バックテスト デフォルト設定
# ============================================================
DEFAULT_SYMBOL   = "USDJPY"
DEFAULT_PERIOD   = 5          # M5 (MT4数値: 1=M1, 5=M5, 15=M15, 60=H1, 240=H4)
DEFAULT_FROM     = "2024.01.01"
DEFAULT_TO       = "2024.12.31"
DEFAULT_MODEL    = 1          # 0=全ティック, 1=始値のみ(高速), 2=コントロールポイント
DEFAULT_DEPOSIT  = 1000000    # 初期証拠金 (円)
DEFAULT_LEVERAGE = 100
DEFAULT_CURRENCY = "JPY"

# バックテスト完了待機タイムアウト (秒)
BACKTEST_TIMEOUT = 1800  # 30分

# ============================================================
# 最適化対象パラメータとその探索範囲
# ============================================================
# grid_search で使用: {パラメータ名: [候補値リスト]}
PARAM_GRID = {
    "InpStopLoss":    [7.0, 10.0, 13.0, 15.0],
    "InpBEPips":      [5.0, 8.0, 10.0],
    "InpTrailStart":  [10.0, 12.0, 15.0],
    "InpTrailPips":   [6.0, 8.0, 10.0],
    "InpMaxSpreadPips": [2.0, 3.0],
}

# EA の固定パラメータ (最適化しないもの)
FIXED_PARAMS = {
    "InpMagic":         20260303,
    "InpSlippage":      3,
    "InpUseRiskLot":    True,
    "InpRiskPercent":   1.0,
    "InpFixedLots":     0.10,
    "InpUseMAFilter":   True,
    "InpFilterMA":      200,
    "InpUseSpreadFilter": True,
    "InpUseTimeFilter": True,
    "InpStartHour":     7,
    "InpEndHour":       22,
    "InpHoldExpansion": True,
    "InpUseBE":         True,
    "InpUseTrail":      True,
    "InpBBPeriod":      5,
    "InpBBDev":         2.0,
    "InpUseDailyLimit": True,
    "InpMaxDailyLoss":  3.0,
}

# ============================================================
# AI 改善設定
# ============================================================
# Claude API キー (環境変数 ANTHROPIC_API_KEY を推奨)
import os
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")

# 改善ループの反復回数
AI_IMPROVE_ITERATIONS = 5

# 改善判定の閾値 (この値以上に PF が上がれば「改善」とみなす)
MIN_PF_IMPROVEMENT = 0.05

# ============================================================
# 結果保存先
# ============================================================
RESULTS_DIR = Path(r"C:\dev\claude\backtest\results")
RESULTS_DIR.mkdir(parents=True, exist_ok=True)
