"""
AI自動改善スクリプト

バックテスト結果をもとに Claude API を使って EA を自動改善し、
改善版をバックテストして検証するループを回す。

使い方:
    python ai_improve.py                   # デフォルト設定で改善ループ実行
    python ai_improve.py --iterations 3    # 改善ループ回数を指定
    python ai_improve.py --dry-run         # API呼び出しせずプロンプトだけ表示

事前準備:
    export ANTHROPIC_API_KEY=sk-ant-...
    pip install anthropic
"""
import re
import sys
import json
import shutil
import argparse
import subprocess
from pathlib import Path
from datetime import datetime

import anthropic

import config
from run_backtest import run_backtest, save_result, print_result
from optimize import calc_score, load_best_params


# ============================================================
# プロンプト生成
# ============================================================

SYSTEM_PROMPT = """あなたはMQL4（MetaTrader 4）のFX自動売買EA（Expert Advisor）の専門家です。
バックテスト結果を分析し、EAのロジックを改善する提案と修正コードを提供します。

以下のルールに従ってください：
1. 回答は必ず JSON 形式で返してください
2. 変更箇所は最小限にとどめる（over-engineeringしない）
3. MQL4の文法に厳密に従う
4. 実際に動作するコードのみ提案する
5. リスク管理を悪化させる変更は行わない

回答フォーマット:
{
  "analysis": "現状のバックテスト結果の分析（日本語）",
  "improvements": ["改善案1", "改善案2", ...],
  "changes": [
    {
      "description": "変更の説明",
      "old_code": "変更前のコード（完全一致する文字列）",
      "new_code": "変更後のコード"
    }
  ],
  "expected_improvement": "期待される改善効果の説明"
}"""


def build_prompt(results_history: list[dict], ea_code: str) -> str:
    """Claude への改善依頼プロンプトを生成"""

    # 直近3回の結果サマリー
    history_lines = []
    for i, r in enumerate(results_history[-3:], 1):
        p = r.get("params", {})
        history_lines.append(
            f"試行{i}: PF={r.get('pf', 0):.4f}  DD={r.get('dd_rel', 0):.2f}%  "
            f"勝率={r.get('win_rate', 0):.1f}%  取引数={r.get('trades', 0)}  "
            f"RR比={r.get('rr_ratio', 0):.3f}  Sharpe={r.get('sharpe', 0):.3f}"
        )
        if p:
            history_lines.append(f"  パラメータ: {json.dumps(p, ensure_ascii=False)}")

    latest = results_history[-1]

    prompt = f"""以下のバックテスト結果をもとに、jaja EA v5 のロジックを改善してください。

## バックテスト結果履歴
{chr(10).join(history_lines)}

## 最新結果の詳細
- 純利益   : {latest.get('profit', 0):.0f} 円
- PF       : {latest.get('pf', 0):.4f}
- 最大DD   : {latest.get('dd_rel', 0):.2f}%
- 取引数   : {latest.get('trades', 0)}
- 勝率     : {latest.get('win_rate', 0):.2f}%
- 平均利益 : {latest.get('avg_win', 0):.0f} 円
- 平均損失 : {latest.get('avg_loss', 0):.0f} 円
- RR比     : {latest.get('rr_ratio', 0):.3f}
- Sharpe   : {latest.get('sharpe', 0):.3f}

## 改善目標
1. PF を 1.3 以上にする
2. 最大DD を 20% 以下に抑える
3. 取引数が30以上を維持する

## 現在のEAコード
```mql4
{ea_code}
```

上記のコードを改善してください。変更は最小限にとどめ、JSON形式で返してください。"""

    return prompt


# ============================================================
# コード適用
# ============================================================

def apply_changes(ea_code: str, changes: list[dict]) -> tuple[str, list[str]]:
    """
    AIが提案した changes を EA コードに適用する。

    Returns:
        (新しいコード, 適用成功した変更の説明リスト)
    """
    applied = []
    new_code = ea_code

    for change in changes:
        old = change.get("old_code", "").strip()
        new = change.get("new_code", "").strip()
        desc = change.get("description", "変更")

        if not old or not new:
            print(f"  [スキップ] 空の変更: {desc}")
            continue

        if old not in new_code:
            print(f"  [失敗] 該当コードが見つかりません: {desc}")
            print(f"    探索文字列の先頭: {old[:80]!r}")
            continue

        new_code = new_code.replace(old, new, 1)
        applied.append(desc)
        print(f"  [適用] {desc}")

    return new_code, applied


def save_improved_ea(code: str, iteration: int) -> Path:
    """改善版EAをファイルに保存"""
    ts  = datetime.now().strftime("%Y%m%d_%H%M%S")
    dst = config.EA_SOURCE.parent / f"jaja_EA_v5_ai_{iteration:02d}_{ts}.mq4"
    dst.write_text(code, encoding="utf-8")
    print(f"[保存] 改善版EA: {dst}")
    return dst


# ============================================================
# AI 改善ループ
# ============================================================

def improve_loop(
    iterations:   int  = config.AI_IMPROVE_ITERATIONS,
    symbol:       str  = config.DEFAULT_SYMBOL,
    period:       int  = config.DEFAULT_PERIOD,
    from_date:    str  = config.DEFAULT_FROM,
    to_date:      str  = config.DEFAULT_TO,
    dry_run:      bool = False,
) -> dict:
    """
    AI改善ループのメイン関数。

    1. 現在のEAでバックテスト実行
    2. 結果をClaudeに送って改善案を取得
    3. EAコードに適用
    4. 再バックテスト
    5. 改善していれば採用、そうでなければ元に戻す
    6. iterations 回繰り返す

    Returns:
        最良の結果dict
    """
    if not dry_run and not config.ANTHROPIC_API_KEY:
        print("[エラー] ANTHROPIC_API_KEY が設定されていません")
        print("  export ANTHROPIC_API_KEY=sk-ant-...")
        sys.exit(1)

    client = None if dry_run else anthropic.Anthropic(api_key=config.ANTHROPIC_API_KEY)

    # 最適化済みのベストパラメータを読み込む (なければデフォルト)
    best_params_list = load_best_params(n=1)
    base_params = best_params_list[0] if best_params_list else {
        "InpStopLoss":      10.0,
        "InpBEPips":        8.0,
        "InpTrailStart":    12.0,
        "InpTrailPips":     8.0,
        "InpMaxSpreadPips": 3.0,
    }

    print(f"\n[AI改善ループ開始]  反復回数: {iterations}")
    print(f"  ベースパラメータ: {base_params}")

    # 現在のEAコードを読み込む
    current_code = config.EA_SOURCE.read_text(encoding="utf-8")

    results_history = []
    best_result = None
    best_code   = current_code
    best_score  = 0.0

    # --- イテレーション0: 現状のEAをベースラインとして計測 ---
    print(f"\n[イテレーション 0/{ iterations}] ベースライン計測")
    baseline = run_backtest(base_params, symbol, period, from_date, to_date)
    if baseline:
        baseline["iteration"] = 0
        results_history.append(baseline)
        best_score  = calc_score(baseline)
        best_result = baseline
        save_result(baseline, f"ai_iter00_baseline.json")
        print(f"  ベースライン スコア: {best_score:.4f}")

    # --- 改善ループ ---
    for it in range(1, iterations + 1):
        print(f"\n{'='*60}")
        print(f"[イテレーション {it}/{iterations}] AI改善フェーズ")

        # プロンプト生成
        prompt = build_prompt(results_history, current_code)

        if dry_run:
            print("\n[DRY RUN] プロンプト:\n")
            print(prompt[:2000], "...(省略)")
            break

        # Claude API 呼び出し
        print("  Claude API を呼び出し中...")
        try:
            message = client.messages.create(
                model="claude-sonnet-4-6",
                max_tokens=8192,
                system=SYSTEM_PROMPT,
                messages=[{"role": "user", "content": prompt}],
            )
            response_text = message.content[0].text
        except Exception as e:
            print(f"  [API エラー] {e}")
            continue

        # JSON パース
        ai_result = _parse_ai_response(response_text)
        if not ai_result:
            print("  [エラー] AIの回答をJSONとしてパースできませんでした")
            continue

        print(f"\n  [AI分析]\n  {ai_result.get('analysis', '')}")
        print(f"\n  [改善案]")
        for imp in ai_result.get("improvements", []):
            print(f"    • {imp}")

        changes = ai_result.get("changes", [])
        if not changes:
            print("  [情報] 変更提案なし")
            continue

        # コード変更を適用
        print(f"\n  [コード変更 {len(changes)}件 を適用中]")
        new_code, applied = apply_changes(current_code, changes)

        if not applied:
            print("  [スキップ] 適用できた変更がありませんでした")
            continue

        # 改善版EAを保存 & EA ファイルを差し替え
        improved_path = save_improved_ea(new_code, it)
        config.EA_SOURCE.write_text(new_code, encoding="utf-8")

        # 改善版でバックテスト
        print(f"\n  [バックテスト] 改善版 v{it} を検証中...")
        new_result = run_backtest(base_params, symbol, period, from_date, to_date)

        if new_result is None:
            print("  [失敗] バックテストが完了しませんでした")
            config.EA_SOURCE.write_text(current_code, encoding="utf-8")
            continue

        new_result["iteration"] = it
        new_result["applied_changes"] = applied
        new_result["analysis"] = ai_result.get("analysis", "")
        save_result(new_result, f"ai_iter{it:02d}.json")
        results_history.append(new_result)

        new_score = calc_score(new_result)
        improvement = new_score - best_score

        print(f"\n  [比較]")
        print(f"    前回スコア: {best_score:.4f}  →  今回スコア: {new_score:.4f}")
        print(f"    改善量: {improvement:+.4f}")

        if improvement > config.MIN_PF_IMPROVEMENT:
            print(f"  [採用] スコアが改善されました ✓")
            best_score  = new_score
            best_result = new_result
            best_code   = new_code
            current_code = new_code
        else:
            print(f"  [却下] 改善が不十分。元のコードに戻します")
            config.EA_SOURCE.write_text(current_code, encoding="utf-8")
            # 改善版ファイルは履歴として残す

    # --- 最終結果を採用 ---
    config.EA_SOURCE.write_text(best_code, encoding="utf-8")
    save_result(best_result, "ai_best_result.json")

    print(f"\n{'='*60}")
    print(f"[AI改善ループ完了]")
    print(f"  最終スコア: {best_score:.4f}")
    print_result(best_result)

    return best_result


# ============================================================
# ユーティリティ
# ============================================================

def _parse_ai_response(text: str) -> dict | None:
    """AIの回答テキストからJSONを抽出してパース"""
    # コードブロック内のJSONを優先的に探す
    patterns = [
        r"```json\s*([\s\S]+?)\s*```",
        r"```\s*([\s\S]+?)\s*```",
        r"(\{[\s\S]+\})",
    ]
    for pattern in patterns:
        m = re.search(pattern, text)
        if m:
            try:
                return json.loads(m.group(1))
            except json.JSONDecodeError:
                continue

    # テキスト全体をJSONとして試みる
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


# ============================================================
# CLI エントリポイント
# ============================================================

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="AI自動改善ループ")
    parser.add_argument("--iterations", type=int, default=config.AI_IMPROVE_ITERATIONS)
    parser.add_argument("--symbol",  default=config.DEFAULT_SYMBOL)
    parser.add_argument("--period",  type=int, default=config.DEFAULT_PERIOD)
    parser.add_argument("--from",    dest="from_date", default=config.DEFAULT_FROM)
    parser.add_argument("--to",      dest="to_date",   default=config.DEFAULT_TO)
    parser.add_argument("--dry-run", action="store_true", help="API呼び出しなしでプロンプト確認")
    args = parser.parse_args()

    best = improve_loop(
        iterations=args.iterations,
        symbol=args.symbol,
        period=args.period,
        from_date=args.from_date,
        to_date=args.to_date,
        dry_run=args.dry_run,
    )
