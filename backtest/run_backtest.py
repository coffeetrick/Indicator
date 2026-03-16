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
        "method=2\n"  # lastparameters.ini: 2=始値のみ(最速) ※terminal.iniとマッピングが逆
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
        'AutoStart':          '1',   # 非公式: 一部バージョンで自動スタートに対応
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

def write_cli_ini(symbol: str, period: int, from_date: str, to_date: str) -> Path:
    """
    Gemini推奨: Test* キーを使ったCLI用INIを生成。
    terminal.exe /config:auto_tester.ini で自動実行を試みる。
    TestModel: 0=全ティック, 1=コントロールポイント, 2=始値のみ (terminal.iniと逆)
    """
    ini_path = config.MT4_TESTER_DIR / "auto_tester.ini"
    period_idx = _PERIOD_INDEX.get(period, 1)
    set_filename = f"{config.EA_NAME}.set"
    content = (
        "[Tester]\n"
        f"TestExpert={config.EA_NAME}\n"
        f"TestSymbol={symbol}\n"
        f"TestPeriod={period_idx}\n"
        "TestModel=2\n"             # 2=始値のみ (CLIのマッピングはterminal.iniと逆)
        "TestDateEnable=true\n"
        f"TestFromDate={from_date}\n"
        f"TestToDate={to_date}\n"
        f"TestReport=Report_{config.EA_NAME}.htm\n"
        "TestReplaceReport=true\n"
        "TestShutdownTerminal=true\n"
        f"TestExpertParameters={set_filename}\n"
    )
    ini_path.write_text(content, encoding="utf-8")
    print(f"[CLI INI] {ini_path}")
    return ini_path


def copy_ea_to_mt4():
    """最新のEAソースをMT4のExpertsフォルダにコピーし、MetaEditorでコンパイルする"""
    dst = config.MT4_EXPERTS_DIR / config.EA_SOURCE.name
    shutil.copy2(config.EA_SOURCE, dst)
    print(f"[EA copy] {dst}")

    # MetaEditorでコンパイルして .ex4 を生成
    metaeditor = Path(config.MT4_EXE).parent / "metaeditor.exe"
    ex4_path = config.MT4_EXPERTS_DIR / f"{config.EA_NAME}.ex4"
    log_path = config.MT4_EXPERTS_DIR / "compile.log"

    print(f"[EA compile] {metaeditor} /compile:{dst}")
    try:
        result = subprocess.run(
            [str(metaeditor), f"/compile:{dst}", f"/log:{log_path}"],
            timeout=60,
        )
        print(f"[EA compile] exit={result.returncode}")
    except subprocess.TimeoutExpired:
        print("[EA compile] timeout")
    except Exception as e:
        print(f"[EA compile] error: {e}")

    # コンパイルログを表示
    if log_path.exists():
        try:
            log_text = log_path.read_text(encoding="utf-16-le", errors="replace")
            for line in log_text.splitlines()[:10]:
                print(f"  {line}")
        except Exception:
            pass

    if ex4_path.exists():
        print(f"[EA compile] OK: {ex4_path}")
    else:
        print(f"[EA compile] WARNING: {ex4_path} not found after compile")


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


def _find_mt4_hwnd(timeout: int = 30) -> int | None:
    """
    MT4のウィンドウハンドルを探す。
    タイトルが「口座番号: FXTF-Live - ブローカー名」の形式のウィンドウを対象とする。
    """
    import win32gui
    import re
    # MT4ウィンドウのタイトルパターン: 数字: FXTF-Live - ～ Co., Ltd.
    pattern = re.compile(r'^\d+:.*FXTF.*Ltd\.')
    start = time.time()
    while time.time() - start < timeout:
        found = []
        def cb(hwnd, _):
            if win32gui.IsWindowVisible(hwnd):
                t = win32gui.GetWindowText(hwnd)
                if pattern.match(t):
                    found.append(hwnd)
        win32gui.EnumWindows(cb, None)
        if found:
            print(f"[MT4] ウィンドウ検出: hwnd={found[0]}")
            return found[0]
        time.sleep(1)
    return None


def _click_start_button(mt4_hwnd, timeout: int = 60) -> bool:
    """
    Strategy Tester の「スタート」ボタンを押す。

    MT4は32ビットアプリのため pywinauto (64ビットPython非対応) は使わない。
    AttachThreadInput で MT4 スレッドにアタッチして SetFocus + BM_CLICK が最も確実。
    失敗時は PostMessage / 座標クリックにフォールバック。
    """
    import win32gui as _wg
    import win32con as _wc
    import win32api as _wa
    import win32process
    import ctypes

    def _find_btn():
        found = []
        def cb(hwnd, _):
            try:
                if _wg.GetClassName(hwnd) == "Button":
                    if _wg.GetWindowText(hwnd) in ("\u30b9\u30bf\u30fc\u30c8", "Start"):
                        found.append(hwnd)
            except Exception:
                pass
            return True
        try:
            _wg.EnumChildWindows(mt4_hwnd, cb, None)
        except Exception:
            pass
        return found[0] if found else None

    def _btn_text(hwnd):
        try:
            return _wg.GetWindowText(hwnd)
        except Exception:
            return ""

    start = time.time()
    attempt = 0
    while time.time() - start < timeout:
        btn_hwnd = _find_btn()
        if btn_hwnd is None:
            time.sleep(1)
            continue

        attempt += 1
        left, top, right, bottom = _wg.GetWindowRect(btn_hwnd)
        cx = (left + right) // 2
        cy = (top + bottom) // 2
        print(f"[Start] hwnd={btn_hwnd} center=({cx},{cy}) attempt={attempt}")

        # --- 方法1: AttachThreadInput + SetFocus + BM_CLICK ---
        try:
            curr_tid = _wa.GetCurrentThreadId()
            tgt_tid, _ = win32process.GetWindowThreadProcessId(btn_hwnd)
            ok = ctypes.windll.user32.AttachThreadInput(curr_tid, tgt_tid, True)
            ctypes.windll.user32.SetFocus(btn_hwnd)
            time.sleep(0.1)
            _wg.SendMessage(btn_hwnd, _wc.BM_CLICK, 0, 0)
            if ok:
                ctypes.windll.user32.AttachThreadInput(curr_tid, tgt_tid, False)
            print("[Start] AttachThreadInput+BM_CLICK sent")
            time.sleep(2)
            t = _btn_text(btn_hwnd)
            print(f"[Start] button text after click: '{t}'")
            if t not in ("\u30b9\u30bf\u30fc\u30c8", "Start", ""):
                print("[Start] confirmed started (BM_CLICK)")
                return True
        except Exception as e:
            print(f"[Start] BM_CLICK error: {e}")

        # --- 方法2: PostMessage WM_LBUTTONDOWN/UP ---
        try:
            rect = _wg.GetClientRect(btn_hwnd)
            bx = (rect[0] + rect[2]) // 2
            by = (rect[1] + rect[3]) // 2
            lp = (by << 16) | (bx & 0xFFFF)
            _wg.PostMessage(btn_hwnd, _wc.WM_LBUTTONDOWN, _wc.MK_LBUTTON, lp)
            time.sleep(0.1)
            _wg.PostMessage(btn_hwnd, _wc.WM_LBUTTONUP, 0, lp)
            print("[Start] PostMessage LBUTTONDOWN/UP sent")
            time.sleep(2)
            t = _btn_text(btn_hwnd)
            if t not in ("\u30b9\u30bf\u30fc\u30c8", "Start", ""):
                print("[Start] confirmed started (PostMessage)")
                return True
        except Exception as e:
            print(f"[Start] PostMessage error: {e}")

        # --- 方法3: 座標クリック (ALTハック + SetForegroundWindow) ---
        try:
            _wa.keybd_event(_wc.VK_MENU, 0, 0, 0)
            _wa.keybd_event(_wc.VK_MENU, 0, _wc.KEYEVENTF_KEYUP, 0)
            time.sleep(0.1)
            try:
                _wg.SetForegroundWindow(mt4_hwnd)
                _wg.BringWindowToTop(mt4_hwnd)
            except Exception:
                pass
            time.sleep(0.8)
            _wa.SetCursorPos((cx, cy))
            time.sleep(0.3)
            _wa.mouse_event(0x0002, 0, 0)
            time.sleep(0.15)
            _wa.mouse_event(0x0004, 0, 0)
            print(f"[Start] coordinate click at ({cx},{cy})")
            time.sleep(2)
            t = _btn_text(btn_hwnd)
            if t not in ("\u30b9\u30bf\u30fc\u30c8", "Start", ""):
                print("[Start] confirmed started (coord click)")
                return True
        except Exception as e:
            print(f"[Start] coord click error: {e}")

        if attempt >= 5:
            print("[Start] 5 attempts failed")
            return False
        time.sleep(1)

    print("[Start] timeout")
    return False


def _wait_for_ex4(timeout: int = 90) -> bool:
    """MT4が .mq4 をコンパイルして .ex4 を生成するまで待機"""
    ex4_path = config.MT4_EXPERTS_DIR / f"{config.EA_NAME}.ex4"
    start = time.time()
    while time.time() - start < timeout:
        if ex4_path.exists():
            print(f"[EA] .ex4 confirmed: {ex4_path}")
            return True
        elapsed = int(time.time() - start)
        if elapsed % 5 == 0:
            print(f"[EA] waiting for .ex4 ... {elapsed}s")
        time.sleep(1)
    print(f"[EA] .ex4 not found after {timeout}s")
    return False


def _test_already_running(mt4_hwnd) -> bool:
    """Strategy Tester が既に実行中かチェック (スタートボタンが消えている or ストップボタンがある)"""
    import win32gui
    found_start = []
    found_stop  = []
    def cb(h, _):
        try:
            if win32gui.GetClassName(h) == "Button":
                t = win32gui.GetWindowText(h)
                if t in ("スタート", "Start"):
                    found_start.append(h)
                elif t in ("ストップ", "Stop"):
                    found_stop.append(h)
        except Exception:
            pass
        return True
    try:
        win32gui.EnumChildWindows(mt4_hwnd, cb, None)
    except Exception:
        pass
    return bool(found_stop) or (not found_start)


def run_mt4_backtest(cli_ini_path: Path = None) -> subprocess.Popen:
    """
    MT4を起動してバックテストを実行。

    起動引数に terminal.ini のパスを渡す (Gemini指摘の根本原因修正)。
    MT4は config= を受け取ることで、その設定ファイルを使いテスターを自動起動する。
    ShutdownTerminal=1 が効いていれば、テスト完了後に自動終了する。

    フォールバック: 自動起動しなかった場合は pywinauto でスタートボタンをクリック。
    """
    # Gemini指摘: terminal.ini のパスを引数として渡す
    terminal_ini = config.MT4_DATA_DIR / "config" / "terminal.ini"
    cmd = [config.MT4_EXE, f"config={terminal_ini}"]
    print(f"[MT4 起動] {' '.join(str(x) for x in cmd)}")
    proc = subprocess.Popen(cmd)

    # MT4ウィンドウ検出 (自動終了した場合はウィンドウが出ない)
    print("[待機] MT4ウィンドウを探しています...")
    hwnd = _find_mt4_hwnd(timeout=40)
    if not hwnd:
        print("[MT4] ウィンドウ未検出 : CLIオートスタートで即終了した可能性あり")
        return proc

    print(f"[MT4] ウィンドウ検出 hwnd={hwnd}")

    # .ex4 が生成されるまで待つ (MT4がコンパイル完了するまでクリックしない)
    if not _wait_for_ex4(timeout=90):
        print("[MT4] WARNING: .ex4 not found, clicking Start anyway")

    time.sleep(2)  # UI描画の追加待ち

    # テストが既に走っているか確認 (自動スタートが効いた場合)
    if _test_already_running(hwnd):
        print("[MT4] test already running: CLI auto-start succeeded")
        return proc

    # フォールバック: スタートボタンをクリック
    print("[MT4] clicking Start button")
    _click_start_button(hwnd, timeout=60)
    return proc


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
        reader = csv.DictReader(f, delimiter=";")
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

    # 2. terminal.ini / lastparameters.ini / .set / CLI INI を生成
    all_params = {**config.FIXED_PARAMS, **params}
    update_terminal_ini_tester(symbol, period, from_date, to_date)
    update_last_parameters(from_date, to_date)
    write_ea_set(all_params)
    cli_ini = write_cli_ini(symbol, period, from_date, to_date)

    # 3. 古い結果を削除
    clean_old_result()

    # 4. MT4 起動 (CLIオートスタート → ボタンクリックの順で試みる)
    proc = run_mt4_backtest(cli_ini)

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
