"""
パラメータ最適化スクリプト

使い方:
    python optimize.py                    # グリッドサーチ (config.PARAM_GRID を使用)
    python optimize.py --top 10           # 上位10件を表示
    python optimize.py --resume           # 途中から再開 (完了済みをスキップ)
"""
import csv
import json
import itertools
import argparse
from datetime import datetime
from pathlib import Path

import config
from run_backtest import run_backtest, save_result, print_result


# ============================================================
# スコア計算
# ============================================================

def calc_score(result: dict) -> float:
    """
    バックテスト結果からスコアを計算する。
    最大化したい指標。

    採点基準:
      - PF が高いほど良い
      - DDが低いほど良い
      - 取引数が少なすぎる場合はペナルティ
    """
    pf     = result.get("pf", 0.0)
    dd_rel = result.get("dd_rel", 100.0)
    trades = result.get("trades", 0)

    if pf <= 0 or trades < 10 or dd_rel > 50.0:
        return 0.0

    # PFを主指標、DDでペナルティ、少ない取引数にも軽いペナルティ
    score = (pf - 1.0) / (1.0 + dd_rel / 100.0)
    if trades < 30:
        score *= (trades / 30.0)  # 取引数が少ないと割引
    return max(score, 0.0)


# ============================================================
# グリッドサーチ
# ============================================================

def grid_search(
    param_grid: dict = None,
    symbol:    str = config.DEFAULT_SYMBOL,
    period:    int = config.DEFAULT_PERIOD,
    from_date: str = config.DEFAULT_FROM,
    to_date:   str = config.DEFAULT_TO,
    top_n:     int = 10,
    resume:    bool = False,
) -> list[dict]:
    """
    全パラメータ組み合わせをバックテストして結果をランキング。

    Args:
        param_grid: {パラメータ名: [候補値リスト]}
        top_n: 上位N件を返す
        resume: True の場合、既存の results/*.json をスキップ

    Returns:
        スコア降順の結果リスト
    """
    if param_grid is None:
        param_grid = config.PARAM_GRID

    # 全組み合わせ生成
    keys   = list(param_grid.keys())
    values = list(param_grid.values())
    combos = list(itertools.product(*values))
    total  = len(combos)

    print(f"\n[グリッドサーチ開始]")
    print(f"  パラメータ数: {len(keys)}")
    print(f"  総組み合わせ数: {total}")
    print(f"  対象: {symbol} M{period}  {from_date}〜{to_date}")

    # 既存結果をロード (resume モード)
    completed_hashes = set()
    all_results = []
    if resume:
        for f in config.RESULTS_DIR.glob("grid_*.json"):
            with open(f) as fp:
                r = json.load(fp)
            all_results.append(r)
            completed_hashes.add(_param_hash(r.get("params", {})))
        print(f"  [再開] 既存結果 {len(all_results)} 件をロード済み")

    # 結果書き出し用CSV (追記モード)
    csv_path = config.RESULTS_DIR / f"grid_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
    fieldnames = ["score", "profit", "pf", "dd_rel", "trades", "win_rate",
                  "rr_ratio", "sharpe"] + keys

    with open(csv_path, "w", newline="", encoding="utf-8") as csv_f:
        writer = csv.DictWriter(csv_f, fieldnames=fieldnames)
        writer.writeheader()

        for idx, combo in enumerate(combos, 1):
            params = dict(zip(keys, combo))
            h = _param_hash(params)

            # resume モード: 既に完了していればスキップ
            if resume and h in completed_hashes:
                print(f"  [{idx}/{total}] スキップ (完了済み): {params}")
                continue

            print(f"\n  [{idx}/{total}] {params}")

            result = run_backtest(
                params,
                symbol=symbol, period=period,
                from_date=from_date, to_date=to_date,
            )

            if result is None:
                print(f"  [スキップ] バックテスト失敗")
                continue

            result["score"] = calc_score(result)

            # JSON 保存
            ts = datetime.now().strftime("%Y%m%d_%H%M%S")
            save_result(result, f"grid_{ts}_{h[:8]}.json")

            all_results.append(result)

            # CSV に追記
            row = {
                "score":    f"{result['score']:.4f}",
                "profit":   f"{result['profit']:.0f}",
                "pf":       f"{result['pf']:.4f}",
                "dd_rel":   f"{result['dd_rel']:.2f}",
                "trades":   result["trades"],
                "win_rate": f"{result['win_rate']:.2f}",
                "rr_ratio": f"{result['rr_ratio']:.4f}",
                "sharpe":   f"{result['sharpe']:.4f}",
            }
            row.update({k: v for k, v in params.items()})
            writer.writerow(row)
            csv_f.flush()

    print(f"\n[グリッドサーチ完了]  結果CSV: {csv_path}")

    # ランキング表示
    ranked = sorted(all_results, key=lambda r: r.get("score", 0), reverse=True)
    print_ranking(ranked[:top_n])
    return ranked


# ============================================================
# ランキング表示
# ============================================================

def print_ranking(results: list[dict]):
    print(f"\n{'='*80}")
    print(f"{'順位':>4}  {'スコア':>7}  {'PF':>7}  {'DD%':>6}  {'勝率':>6}  {'取引':>5}  パラメータ")
    print(f"{'='*80}")
    for i, r in enumerate(results, 1):
        p = r.get("params", {})
        param_str = "  ".join(f"{k}={v}" for k, v in p.items())
        print(
            f"{i:>4}  "
            f"{r.get('score', 0):>7.4f}  "
            f"{r.get('pf', 0):>7.4f}  "
            f"{r.get('dd_rel', 0):>6.2f}  "
            f"{r.get('win_rate', 0):>6.2f}  "
            f"{r.get('trades', 0):>5}  "
            f"{param_str}"
        )
    print(f"{'='*80}")


# ============================================================
# ユーティリティ
# ============================================================

def _param_hash(params: dict) -> str:
    """パラメータセットの短いハッシュ文字列を生成"""
    import hashlib
    s = json.dumps(params, sort_keys=True)
    return hashlib.md5(s.encode()).hexdigest()


def load_best_params(n: int = 1) -> list[dict]:
    """保存済み結果から上位Nのパラメータを読み込む"""
    results = []
    for f in config.RESULTS_DIR.glob("*.json"):
        with open(f) as fp:
            r = json.load(fp)
        r["score"] = calc_score(r)
        results.append(r)

    ranked = sorted(results, key=lambda r: r["score"], reverse=True)
    return [r["params"] for r in ranked[:n]]


# ============================================================
# CLI エントリポイント
# ============================================================

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="パラメータ最適化")
    parser.add_argument("--symbol",  default=config.DEFAULT_SYMBOL)
    parser.add_argument("--period",  type=int, default=config.DEFAULT_PERIOD)
    parser.add_argument("--from",    dest="from_date", default=config.DEFAULT_FROM)
    parser.add_argument("--to",      dest="to_date",   default=config.DEFAULT_TO)
    parser.add_argument("--top",     type=int, default=10, help="上位N件表示")
    parser.add_argument("--resume",  action="store_true", help="途中から再開")
    args = parser.parse_args()

    grid_search(
        symbol=args.symbol,
        period=args.period,
        from_date=args.from_date,
        to_date=args.to_date,
        top_n=args.top,
        resume=args.resume,
    )
