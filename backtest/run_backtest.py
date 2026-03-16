"""
MT4 バックテスト自動実行スクリプト

使い方:
    python run_backtest.py                          # デフォルト設定で1回実行
    python run_backtest.py --symbol EURUSD          # 通貨ペア指定
    python run_backtest.py --from 2023.01.01 --to 2024.12.31
"""
import subprocess
import time
import shutil
import argparse
import csv
import json
from datetime import datetime
from pathlib import Path

import config


# ============================================================
# INI / SET ファイル生成
# ============================================================

def _detect_encoding(raw: bytes):
    """INIファイルのエンコーディングを検出してテキストとメタ情報を返す"""
    if raw[:2] == b'\xff\xfe':
        return raw[2:].decode('utf-16-le'), 'utf-16-le', b'\xff\xfe'
    if raw[:2] == b'\xfe\xff':
        return raw[2:].decode('utf-16-be'), 'utf-16-be', b'\xfe\xff'
    try:
        return raw.decode('utf-8'), 'utf-8', b''
    except UnicodeDecodeError:
        return raw.decode('cp932', errors='replace'), 'cp932', b''


# terminal.ini の Period フィールドは MT4 タイムフレームのインデックス値
_PERIOD_INDEX = {1: 0, 5: 1, 15: 2, 30: 3, 60: 4, 240: 5, 1440: 6, 10080: 7, 43200: 8}


def _date_to_unix(date_str: str) -> int:
    """'2024.01.01' → Unix タイムスタンプ (UTC)"""
    from datetime import datetime, timezone
    dt = datetime.strptime(date_str, "%Y.%m.%d").replace(tzinfo=timezone.utc)
    return int(dt.timestamp())


def update_last_parameters(from_date: str, to_date: str):
    """lastparameters.ini の日付をUnixタイムスタンプで更新"""
    path = config.MT4_TESTER_DIR / "lastparameters.ini"
    content = (
        "optimization=0\n"
        "genetic=1\n"
        "fitnes=0\n"
        "method=0\n"
        "use_date=1\n"
        f"from={_date_to_unix(from_date)}\n"
        f"to={_date_to_unix(to_date)}\n"
    )
    path.write_text(content, encoding="utf-8")
    print(f"[lastparameters.ini 更新] {from_date}〜{to_date} "
          f"({_date_to_unix(from_date)}〜{_date_to_unix(to_date)})")


def update_terminal_ini_tester(symbol: str, period: int,
                               from_date: str, to_date: str):
    """
    MT4の terminal.ini の [Tester] セクションを直接書き換える。
    MT4はこのファイルをストラテジーテスターの設定として読む。
    """
    ini_path = config.MT4_DATA_DIR / "config" / "terminal.ini"
    raw = ini_path.read_bytes()
    text, encoding, bom = _detect_encoding(raw)

    period_idx = _PERIOD_INDEX.get(period, 1)  # デフォルトM5=1

    tester_updates = {
        'Expert':             f"{config.EA_NAME}.ex4",
        'ExpertParameters':   f"{config.EA_NAME}.set",
        'Symbol':             symbol,
        'Period':             str(period_idx),
        'Optimization':       '0',
        'Model':              str(config.DEFAULT_MODEL),
        'Deposit':            str(config.DEFAULT_DEPOSIT),
        'Leverage':           str(config.DEFAULT_LEVERAGE),
        'Currency':           config.DEFAULT_CURRENCY,
        'ShutdownTerminal':   '1',
        'VisualChart':        '0',
    }

    lines = text.splitlines(keepends=True)
    in_tester = False
    new_lines = []
    written_keys: set = set()

    for line in lines:
        stripped = line.strip()

        # セクション境界
        if stripped.startswith('['):
            if in_tester:
                # [Tester]を抜ける前に未書込みキーを追加
                for k, v in tester_updates.items():
                    if k not in written_keys:
                        new_lines.append(f"{k}={v}\r\n")
                in_tester = False
            in_tester = (stripped.lower() == '[tester]')
            new_lines.append(line)
            continue

        # [Tester]内のキーを上書き
        if in_tester and '=' in stripped:
            key = stripped.split('=')[0].strip()
            if key in tester_updates:
                new_lines.append(f"{key}={tester_updates[key]}\r\n")
                written_keys.add(key)
                continue

        new_lines.append(line)

    # ファイル末尾が[Tester]だった場合
    if in_tester:
        for k, v in tester_updates.items():
            if k not in written_keys:
                new_lines.append(f"{k}={v}\r\n")

    new_text = ''.join(new_lines)
    ini_path.write_bytes(bom + new_text.encode(encoding, errors='replace'))
    print(f"[terminal.ini 更新] encoding={encoding} Symbol={symbol} "
          f"Period=M{period} {from_date}〜{to_date}")


def write_ea_set(params: dict) -> Path:
    """
    MT4 EAパラメータ .set ファイルを書き出す。
    """
    set_path = config.MT4_TESTER_DIR / f"{config.EA_NAME}.set"
    lines = []

    def fmt_val(v):
        if isinstance(v, bool):
            return "1" if v else "0"
        if isinstance(v, float):
            return f"{v:.8f}"
        return str(v)

    for key, val in params.items():
        lines.append(f"{key}={fmt_val(val)}")
        lines.append(f"{key},F=0")

    set_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return set_path


# ============================================================
# MT4 起動 & 完了待ち
# ============================================================

def copy_ea_to_mt4():
    """最新のEAソースをMT4のExpertsフォルダにコピーする"""
    dst = config.MT4_EXPERTS_DIR / config.EA_SOURCE.name
    shutil.copy2(config.EA_SOURCE, dst)
    print(f"[EA コピー] {dst}")


def wait_for_result(timeout: int = config.BACKTEST_TIMEOUT) -> bool:
    """backtest_result.csv が生成されるまで待機"""
    result_file = config.MT4_TESTER_FILES / "backtest_result.csv"
    start = time.time()
    print(f"[待機] バックテスト完了を待機中 (最大{timeout}秒)...")

    while time.time() - start < timeout:
        if result_file.exists():
            # ファイル書き込み完了を待つ
            time.sleep(2)
            return True
        time.sleep(5)
        elapsed = int(time.time() - start)
        if elapsed % 30 == 0:
            print(f"  ... {elapsed}秒経過")

    print("[タイムアウト] バックテストが完了しませんでした")
    return False


def run_mt4_backtest() -> subprocess.Popen:
    """MT4をバックテストモードで起動"""
    cmd = [config.MT4_EXE]
    print(f"[MT4 起動] {config.MT4_EXE}")
    return subprocess.Popen(cmd)


# ============================================================
# 結果解析
# ============================================================

def parse_result() -> dict | None:
    """
    OnTester() が書き出した backtest_result.csv を読み込む。
    Returns: 結果dict or None (失敗時)
    """
    result_file = config.MT4_TESTER_FILES / "backtest_result.csv"
    if not result_file.exists():
        print("[エラー] backtest_result.csv が見つかりません")
        return None

    with open(result_file, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        rows = list(reader)

    if not rows:
        print("[エラー] 結果ファイルが空です")
        return None

    row = rows[0]
    return {
        "profit":   float(row["profit"]),
        "pf":       float(row["pf"]),
        "dd_rel":   float(row["dd_rel"]),
        "dd_abs":   float(row["dd_abs"]),
        "trades":   int(row["trades"]),
        "win_rate": float(row["win_rate"]),
        "avg_win":  float(row["avg_win"]),
        "avg_loss": float(row["avg_loss"]),
        "rr_ratio": float(row["rr_ratio"]),
        "sharpe":   float(row["sharpe"]),
    }


def clean_old_result():
    """古い結果ファイルを削除"""
    result_file = config.MT4_TESTER_FILES / "backtest_result.csv"
    if result_file.exists():
        result_file.unlink()


# ============================================================
# メイン実行関数
# ============================================================

def run_backtest(
    params: dict,
    symbol:    str = config.DEFAULT_SYMBOL,
    period:    int = config.DEFAULT_PERIOD,
    from_date: str = config.DEFAULT_FROM,
    to_date:   str = config.DEFAULT_TO,
    timeout:   int = config.BACKTEST_TIMEOUT,
) -> dict | None:
    """
    1回のバックテストを実行して結果を返す。

    Returns:
        結果dict: {profit, pf, dd_rel, dd_abs, trades, win_rate, ...}
        None: 失敗時
    """
    print(f"\n{'='*60}")
    print(f"[バックテスト開始]")
    print(f"  Symbol: {symbol}  Period: M{period}")
    print(f"  期間: {from_date} 〜 {to_date}")
    print(f"  パラメータ: { {k: v for k, v in params.items() if k.startswith('Inp')} }")
    print(f"{'='*60}")

    # 1. EA をコピー
    copy_ea_to_mt4()

    # 2. terminal.ini の [Tester] と lastparameters.ini を更新
    all_params = {**config.FIXED_PARAMS, **params}
    update_terminal_ini_tester(symbol, period, from_date, to_date)
    update_last_parameters(from_date, to_date)
    write_ea_set(all_params)

    # 3. 古い結果を削除
    clean_old_result()

    # 4. MT4 起動
    proc = run_mt4_backtest()

    # 5. 完了待ち
    completed = wait_for_result(timeout)

    # 6. MT4 が残っていれば終了させる
    if proc.poll() is None:
        proc.terminate()
        proc.wait(timeout=10)

    if not completed:
        return None

    # 7. 結果解析
    result = parse_result()
    if result:
        result["params"]    = params
        result["symbol"]    = symbol
        result["period"]    = period
        result["from_date"] = from_date
        result["to_date"]   = to_date
        result["timestamp"] = datetime.now().isoformat()
        print_result(result)

    return result


def print_result(r: dict):
    """結果を見やすく表示"""
    print(f"\n[結果]")
    print(f"  純利益     : {r['profit']:>10.0f} 円")
    print(f"  PF         : {r['pf']:>10.4f}")
    print(f"  最大DD     : {r['dd_rel']:>9.2f} %")
    print(f"  取引数     : {r['trades']:>10}")
    print(f"  勝率       : {r['win_rate']:>9.2f} %")
    print(f"  平均利益   : {r['avg_win']:>10.0f} 円")
    print(f"  平均損失   : {r['avg_loss']:>10.0f} 円")
    print(f"  RR比       : {r['rr_ratio']:>10.4f}")
    print(f"  Sharpe     : {r['sharpe']:>10.4f}")


def save_result(result: dict, filename: str = None):
    """結果をJSONファイルに保存"""
    if filename is None:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"result_{ts}.json"
    path = config.RESULTS_DIR / filename
    with open(path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    print(f"[保存] {path}")
    return path


# ============================================================
# CLI エントリポイント
# ============================================================

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="MT4 バックテスト自動実行")
    parser.add_argument("--symbol",   default=config.DEFAULT_SYMBOL)
    parser.add_argument("--period",   type=int, default=config.DEFAULT_PERIOD)
    parser.add_argument("--from",     dest="from_date", default=config.DEFAULT_FROM)
    parser.add_argument("--to",       dest="to_date",   default=config.DEFAULT_TO)
    parser.add_argument("--sl",       type=float, default=10.0, help="StopLoss pips")
    parser.add_argument("--be",       type=float, default=8.0,  help="BreakEven pips")
    parser.add_argument("--trail-start", type=float, default=12.0)
    parser.add_argument("--trail-pips",  type=float, default=8.0)
    args = parser.parse_args()

    params = {
        "InpStopLoss":     args.sl,
        "InpBEPips":       args.be,
        "InpTrailStart":   args.trail_start,
        "InpTrailPips":    args.trail_pips,
        "InpMaxSpreadPips": 3.0,
    }

    result = run_backtest(
        params,
        symbol=args.symbol,
        period=args.period,
        from_date=args.from_date,
        to_date=args.to_date,
    )

    if result:
        save_result(result)
