#!/usr/bin/env python3
"""
青山学院ポータル「時間割・講義内容検索」(kouginaiyou/kensaku.aspx) を
巡回してシラバス一覧を取得し、LocalSyllabusIndex.swift の SyllabusRaw
と同じ形の JSON を出力するスクリプト。

── 仕組み ──
ログインは Playwright でブラウザを開いて手動で行う。検索・ページ送りは
そのブラウザで実際にフォームに入力して検索ボタンを押し、「次へ」リンクを
クリックして進める（生のHTTPリクエストでURLのPGパラメータだけを変えて
飛ばす方式は試したが、このサイトのページ送りは表示中のページ送りリンクが
持つ内部ID（__EVENTTARGET）が必須で、それを再現しない限りPGの値を変えても
常に1ページ目が返ってくるだけだったため、実際のクリックに戻した）。

このサイトは Ajax の部分更新（UpdatePanel）でテーブルを差し替えるため、
クリック直後はまだ古いページの内容が残っていることがある。そのため
テーブル1行目の内容が実際に変わったこと（＋隠しフィールド CPH1_PI の値）
まで確認してから読み取る。

── 使い方 ──
1) 依存関係:
     pip3 install playwright beautifulsoup4
     python3 -m playwright install chromium
2) 実行:
     python3 scripts/scrape_syllabus.py --gkb "" --out scripts/output/syllabus_index.json
   ブラウザが開くので、そこで自分でポータルにログイン（多要素認証含む）し、
   検索画面が表示されたらターミナルで Enter を押す。
   ログイン状態は scripts/.aguinfo_state.json に保存され、次回以降は
   セッションが有効な間は自動ログインをスキップする。

── 注意 ──
- ログイン（パスワード・多要素認証の入力）は必ず自分の手で行うこと。
  このスクリプトは一切の認証情報を扱わない。
- --delay で各ページ送り間隔（秒）を調整できる。大学のサーバーに
  過剰な負荷をかけないよう、既定値より短くしないこと。
- 個人利用・アプリ内シラバス検索データの更新用途を想定。再配布や
  大学の利用規約に反する用途には使わないこと。
- 途中でエラーになっても、その時点までの結果は出力ファイルに保存される。
  もう一度実行すると保存済みログインセッションから再開でき、重複はID
  （登録番号ベースの科目コード）で自動的に除外される。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import unicodedata
from pathlib import Path
from urllib.parse import urljoin, urlparse, parse_qs

from bs4 import BeautifulSoup
from playwright.sync_api import sync_playwright

BASE_URL = "https://aguinfo.jm.aoyama.ac.jp/kouginaiyou/kensaku.aspx"
DEFAULT_STATE_PATH = Path(__file__).parent / ".aguinfo_state.json"

# 学部 (BU) の選択肢。とりあえず第一部（学部生・昼間）のみを既定にする。
BU_CHOICES = {
    "day": "BU1",       # 第一部
    "evening": "BU2",   # 第二部
    "graduate": "BU3",  # 大学院
    "professional": "BU4",
}

CAMPUS_CHECKBOX_IDS = {
    "CP1": "#CPH1_rptCP_CP_0",  # 青山
    "CP4": "#CPH1_rptCP_CP_1",  # 相模原
}

BU_RADIO_IDS = {
    "BU1": "#CPH1_BU1",
    "BU2": "#CPH1_BU2",
    "BU3": "#CPH1_BU3",
    "BU4": "#CPH1_BU4",
}

# 曜日・時限チェックボックス。無条件で全件検索すると数百ページにわたり
# ページ送りが不安定になりやすいため曜日単位で分割する（PERIOD_CHECKBOX_IDS
# は分割には使わない: 曜日×時限のように時限側も単一値に絞ると、複数時限に
# またがる授業がヒットしなくなり取得漏れの原因になることが判明したため、
# 時限側は常に未チェック＝フィルタなしのまま検索する）。
DAY_CHECKBOX_IDS = {
    "月": "#CPH1_rptYB_YB_0", "火": "#CPH1_rptYB_YB_1", "水": "#CPH1_rptYB_YB_2",
    "木": "#CPH1_rptYB_YB_3", "金": "#CPH1_rptYB_YB_4", "土": "#CPH1_rptYB_YB_5",
    "不定": "#CPH1_rptYB_YB_6",
}
PERIOD_CHECKBOX_IDS = {
    "1": "#CPH1_rptJG_JG_0", "2": "#CPH1_rptJG_JG_1", "3": "#CPH1_rptJG_JG_2",
    "4": "#CPH1_rptJG_JG_3", "5": "#CPH1_rptJG_JG_4", "6": "#CPH1_rptJG_JG_5",
    "7": "#CPH1_rptJG_JG_6", "不定": "#CPH1_rptJG_JG_7",
}


def to_halfwidth_digits(s: str) -> str:
    return unicodedata.normalize("NFKC", s or "")


def run_search(page, *, bu: str, gkb: str, campuses: list[str],
                keyword: str, class_name: str, teacher: str,
                day_label: str | None = None, period_label: str | None = None) -> None:
    """検索フォームに実際に値を入れて検索ボタンを押す（手動操作と同じ経路）。

    day_label/period_label を指定すると、その曜日・時限だけに絞り込む
    （それ以外の曜日・時限チェックボックスは全て外す）。
    """
    page.check(BU_RADIO_IDS[bu])
    for code, sel in CAMPUS_CHECKBOX_IDS.items():
        if code in campuses:
            page.check(sel)
        else:
            page.uncheck(sel)
    for label, sel in DAY_CHECKBOX_IDS.items():
        if label == day_label:
            page.check(sel)
        else:
            page.uncheck(sel)
    for label, sel in PERIOD_CHECKBOX_IDS.items():
        if label == period_label:
            page.check(sel)
        else:
            page.uncheck(sel)
    prev_sig = get_first_row_signature(page)
    page.fill("#CPH1_KW", keyword)
    page.fill("#CPH1_KM", class_name)
    page.fill("#CPH1_KI", teacher)
    page.select_option("#CPH1_GKB", value=gkb)

    last_err: Exception | None = None
    for attempt in range(1, 6):
        try:
            page.click("#CPH1_btnKensaku")
            # テーブル1行目の内容が実際に前の条件から変わったこと（＋PI==0）を確認する。
            # 件数（検索結果◯件）は条件を変えるたびほぼ必ず変わるため、それだけを
            # 見ると「件数表示だけ先に更新され、テーブル本体はまだ古いまま」という
            # タイミングを見逃してしまう。ここでは実際の行内容の変化だけを信じる。
            wait_for_table_change(page, prev_sig, 1)
            return
        except Exception as e:  # noqa: BLE001
            # ごく稀に、前の条件の1行目とたまたま同じ内容になることがある
            # （例えば偶然同じ科目が両方の条件でトップに来る場合）。
            # その場合は現在の内容を基準に取り直してリトライする。
            last_err = e
            backoff = 5 * attempt
            print(f"  (検索結果の切り替わり待ちがタイムアウト。{backoff}秒待ってリトライ {attempt}/5)")
            time.sleep(backoff)
            prev_sig = get_first_row_signature(page)
    assert last_err is not None
    raise last_err


def get_first_row_signature(page) -> str | None:
    """結果テーブルの1行目のテキストを取得する（ページが実際に切り替わったかの判定用）。"""
    return page.evaluate(
        "() => { const t = document.querySelector('table#CPH1_gvw_kensaku'); "
        "const tr = t && t.querySelector('tbody tr'); return tr ? tr.innerText : null; }"
    )


def wait_for_page_index(page, target_page: int, timeout: float = 20000) -> None:
    """隠しフィールド CPH1_PI（現在ページの0始まり番号）が目的の値になるまで待つ。"""
    page.wait_for_function(
        "expected => { const el = document.querySelector('#CPH1_PI'); "
        "return !!el && el.value === expected; }",
        arg=str(target_page - 1),
        timeout=timeout,
    )


def wait_for_table_change(page, prev_signature: str | None, target_page: int,
                           timeout: float = 45000) -> None:
    """PI の更新に加えて、テーブル1行目の内容が実際に変わったことまで確認する。

    このページは ASP.NET の部分更新(UpdatePanel)で結果テーブルを差し替えるため、
    PI の値だけを見ていると、テーブル本体の再描画がまだ終わっていない
    （＝前ページの内容が残っている）タイミングで読んでしまうことがある。
    """
    page.wait_for_function(
        "(args) => { const t = document.querySelector('table#CPH1_gvw_kensaku'); "
        "const tr = t && t.querySelector('tbody tr'); "
        "const sig = tr ? tr.innerText : null; "
        "const pi = document.querySelector('#CPH1_PI'); "
        "return (sig === null || sig !== args.prev) && !!pi && pi.value === args.target; }",
        arg={"prev": prev_signature, "target": str(target_page - 1)},
        timeout=timeout,
    )


class PagerLinkNotFound(Exception):
    """ページ番号/次へリンクが見つからなかったが、まだ最終ページのはずではない場合。"""


def click_next_page(page, target_page: int, prev_signature: str | None,
                     expected_page_count: int | None = None,
                     retries: int = 10, timeout_ms: float = 60000) -> bool:
    """次ページへ進む。「次へ」矢印を優先し、無ければページ番号リンクを直接探す。

    大学サーバー側が一時的に遅くなる/レート制限気味になることがあるほか、
    UpdatePanel の差し替え中にページャー部分が一時的にDOMから消えている
    タイミングでリンクが見つからないことがある。target_page が既知の
    expected_page_count を超えていない限り「リンクが無い＝最終ページ」と
    即断せず、他の例外と同じくバックオフしてリトライする。
    """
    last_err: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            next_link = page.locator('a[id*="lnkNext"]')
            if next_link.count() > 0:
                next_link.first.click()
                wait_for_table_change(page, prev_signature, target_page, timeout=timeout_ms)
                return True

            num_link = page.get_by_role("link", name=str(target_page), exact=True)
            if num_link.count() > 0:
                num_link.first.click()
                wait_for_table_change(page, prev_signature, target_page, timeout=timeout_ms)
                return True

            # 本当に最終ページに到達している場合のみ、ここで正常終了として扱う。
            if expected_page_count is not None and target_page > expected_page_count:
                return False

            raise PagerLinkNotFound(
                f"ページ{target_page}へのリンクが見つかりません "
                f"(expected_page_count={expected_page_count})"
            )
        except Exception as e:  # noqa: BLE001
            last_err = e
            backoff = min(90, 10 * attempt)  # 10s, 20s, ..., 90s（上限）
            print(f"  (ページ{target_page}への遷移待ちがタイムアウト。{backoff}秒待ってリトライ {attempt}/{retries})")
            time.sleep(backoff)
            # リトライ時は最新の内容を基準に取り直す（前回の試行で実は進んでいた場合に対応）
            prev_signature = get_first_row_signature(page)

    assert last_err is not None
    raise last_err


def parse_jigen(td) -> tuple[str | None, str | None, list[int]]:
    """td.col2 の中身から (campus, day, periods) を取り出す。"""
    outer = td.find("span", id=True)
    if not outer:
        return None, None, []
    parts = outer.find_all("span", recursive=False)
    campus = day = None
    periods: list[int] = []
    for i, p in enumerate(parts):
        text = p.get_text(strip=True)
        if i == 0:
            campus = text.strip("[]")
        elif i == 1:
            text = to_halfwidth_digits(text)
            m = re.match(r"([月火水木金土日])(.*)", text)
            if m:
                day = m.group(1)
                periods = [int(x) for x in re.findall(r"\d+", m.group(2))]
        elif i == 2:
            # term は行ごとに term フィールドとして別途返す
            pass
    return campus, day, periods


def parse_term(td) -> str | None:
    outer = td.find("span", id=True)
    if not outer:
        return None
    parts = outer.find_all("span", recursive=False)
    if len(parts) >= 3:
        text = parts[2].get_text(strip=True)
        # 例: "（前期）/First Semester" のように括弧の後に英語表記が続くことがあるため、
        # 括弧の中身だけを取り出す（.strip("（）()") では末尾に他の文字が
        # 続く場合に取り切れず "前期）/" のような壊れた値になっていた）。
        m = re.search(r"[（(]([^）)]+)[）)]", text)
        return m.group(1) if m else text.strip("（）()")
    return None


def parse_page(html: str, page_url: str) -> tuple[list[dict], int, int | None, dict[str, int], list[dict]]:
    """1ページ分の検索結果 HTML から科目リスト・ページ数・総件数を取り出す。

    4つ目の戻り値は、行として数えられなかった理由ごとの件数
    （{"few_cols": N, "no_name": N}）。5つ目は捨てられた行そのものの中身
    （デバッグ用。共通性がないか目視で確認できるように、取れる範囲の
    セル内容をそのまま残す）。
    """
    soup = BeautifulSoup(html, "html.parser")
    table = soup.select_one("table#CPH1_gvw_kensaku")
    results: list[dict] = []
    skipped = {"few_cols": 0, "no_name": 0}
    skipped_rows: list[dict] = []
    if table:
        for tr in table.select("tbody > tr"):
            cols = tr.find_all("td", recursive=False)
            if len(cols) < 9:
                skipped["few_cols"] += 1
                skipped_rows.append({
                    "reason": "few_cols",
                    "page_url": page_url,
                    "td_count": len(cols),
                    "cells": [c.get_text(" ", strip=True) for c in cols],
                    "raw_html": str(tr),
                })
                continue
            col = {c["class"][0]: c for c in cols if c.get("class")}

            reg_no_raw = (col["col1"].get_text(strip=True) if "col1" in col else "") or ""
            reg_no = reg_no_raw if re.fullmatch(r"\d+", reg_no_raw) else None

            campus, day, periods = parse_jigen(col["col2"]) if "col2" in col else (None, None, [])
            term = parse_term(col["col2"]) if "col2" in col else None

            name = col["col3"].get_text(strip=True) if "col3" in col else ""
            teacher = col["col4"].get_text(strip=True) if "col4" in col else ""
            room = col["col5"].get_text(strip=True) if "col5" in col else ""
            credit_raw = col["col6"].get_text(strip=True) if "col6" in col else ""
            credit = int(credit_raw) if credit_raw.isdigit() else None
            category = col["col7"].get_text(strip=True) if "col7" in col else ""
            grade = col["col9"].get_text(separator=" ", strip=True) if "col9" in col else ""

            link = col["col8"].find("a", href=True) if "col8" in col else None
            detail_url = urljoin(page_url, link["href"]) if link else None
            fn = None
            if detail_url:
                qs = parse_qs(urlparse(detail_url).query)
                fn = (qs.get("FN") or [None])[0]

            if not name:
                skipped["no_name"] += 1
                skipped_rows.append({
                    "reason": "no_name",
                    "page_url": page_url,
                    "registration_number": reg_no,
                    "campus": campus,
                    "day": day,
                    "periods": periods,
                    "term": term,
                    "teacher_name": teacher,
                    "room": room,
                    "credit": credit,
                    "category": category,
                    "grade": grade,
                    "code": fn,
                    "cells": [c.get_text(" ", strip=True) for c in cols],
                    "raw_html": str(tr),
                })
                continue

            results.append({
                "id": fn or f"{name}_{teacher}",
                "class_name": name,
                "teacher_name": teacher,
                "category": category,
                "grade": grade,
                "campus": [campus] if campus else [],
                "time": {"day": day, "periods": periods},
                "term": term or "",
                "credit": credit,
                "eval_method": None,
                "url": detail_url,
                "syllabusURL": detail_url,
                "registration_number": reg_no,
                "code": fn,
                "class_code": fn,
                "course_code": fn,
                "room": room,
            })

    pc_input = soup.select_one("#CPH1_PC")
    page_count = int(pc_input["value"]) if pc_input and pc_input.get("value", "").isdigit() else (1 if results else 0)

    hit_span = soup.select_one("#CPH1_lblHitMsg")
    total_hits = int(hit_span.get_text(strip=True)) if hit_span and hit_span.get_text(strip=True).isdigit() else None

    return results, page_count, total_hits, skipped, skipped_rows


def get_stable_content(page, tries: int = 6, wait: float = 0.5) -> str:
    """遷移直後は content() が失敗することがあるのでリトライする。"""
    last_err: Exception | None = None
    for _ in range(tries):
        try:
            page.wait_for_load_state("networkidle")
            return page.content()
        except Exception as e:  # noqa: BLE001
            last_err = e
            time.sleep(wait)
    assert last_err is not None
    raise last_err


def ensure_logged_in(page, state_path: Path) -> None:
    page.goto(BASE_URL)
    page.wait_for_load_state("networkidle")
    if "kouginaiyou/kensaku.aspx" in page.url:
        return  # 既存セッションで既にログイン済み

    print("\n=== ログインが必要です ===")
    print("開いたブラウザでポータルにログインしてください（多要素認証を含む）。")
    print("※ ブラウザのウィンドウは自分では閉じないこと。ログインが終わって")
    print("  「時間割・講義内容検索」の画面が表示されるまで、このターミナルには")
    print("  戻らずブラウザ側の操作を先に終わらせてください。")

    while True:
        input("\n「時間割・講義内容検索」の検索フォームが表示されたら Enter を押す > ")

        if page.is_closed():
            print("エラー: ブラウザのウィンドウが閉じられています。")
            print("スクリプトをもう一度実行し、今度はログインが完全に終わって")
            print("検索フォームが表示されるまでブラウザを閉じずに待ってください。")
            sys.exit(1)

        page.wait_for_load_state("networkidle")
        if "kouginaiyou/kensaku.aspx" in page.url:
            break

        print(f"まだ検索ページに到達していません (現在のURL: {page.url})")
        print("ブラウザでログイン・認証を続けてから、もう一度Enterを押してください。")

    page.context.storage_state(path=str(state_path))
    print(f"ログインセッションを {state_path} に保存しました。")


def save_results(all_results: list[dict], out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as f:
        json.dump(all_results, f, ensure_ascii=False, indent=2)


def load_existing_results(out_path: Path) -> list[dict]:
    """前回までに保存済みの出力ファイルがあれば読み込む（再実行時の再開用）。"""
    if not out_path.exists():
        return []
    try:
        with out_path.open(encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, list):
            return data
    except Exception:  # noqa: BLE001
        pass
    return []


def progress_path_for(out_path: Path) -> Path:
    return out_path.with_name(out_path.name + ".progress.json")


def load_completed_combos(out_path: Path) -> set[str]:
    """前回までに完走できた検索条件（曜日×時限）のラベル集合を読み込む。

    途中で失敗した条件は含めない（再実行時にやり直すため）。
    """
    p = progress_path_for(out_path)
    if not p.exists():
        return set()
    try:
        with p.open(encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, list):
            return set(data)
    except Exception:  # noqa: BLE001
        pass
    return set()


def save_completed_combos(out_path: Path, completed: set[str]) -> None:
    p = progress_path_for(out_path)
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("w", encoding="utf-8") as f:
        json.dump(sorted(completed), f, ensure_ascii=False, indent=2)


def crawl_one_search(page, *, bu: str, gkb: str, campuses: list[str],
                      keyword: str, class_name: str, teacher: str,
                      day_label: str | None, period_label: str | None,
                      delay: float, seen_ids: set[str], all_results: list[dict],
                      all_skipped_rows: list[dict], label: str) -> None:
    """1つの検索条件（曜日・時限の絞り込みなど）について検索し、全ページを巡回する。"""
    run_search(page, bu=bu, gkb=gkb, campuses=campuses,
               keyword=keyword, class_name=class_name, teacher=teacher,
               day_label=day_label, period_label=period_label)

    before_count = len(all_results)
    # この条件だけで実際に読み取れた行数（グローバルな重複除外とは別に数える）。
    # 「新規追加件数」は他の曜日条件で既に拾い済みの授業（複数曜日にまたがる
    # 授業など）があると total_hits より少なくなるのが正常なので、この条件の
    # ページングが本当に漏れなく完走したかどうかは、こちらの値で判定する。
    combo_seen_ids: set[str] = set()
    combo_skipped = {"few_cols": 0, "no_name": 0}

    html = get_stable_content(page)
    rows, page_count, total_hits, skipped, skipped_rows = parse_page(html, page.url)
    combo_skipped["few_cols"] += skipped["few_cols"]
    combo_skipped["no_name"] += skipped["no_name"]
    for sr in skipped_rows:
        sr["label"] = label
        all_skipped_rows.append(sr)
    for r in rows:
        combo_seen_ids.add(r["id"])
        if r["id"] not in seen_ids:
            seen_ids.add(r["id"])
            all_results.append(r)

    if page_count > 1:
        print(f"  [{label}] 1 / {page_count} ページ (検索結果 {total_hits} 件)")

    pg = 1
    prev_sig = get_first_row_signature(page)
    while True:
        time.sleep(delay)
        if pg % 50 == 0:
            print(f"  ({pg}ページ経過。30秒休憩...)")
            time.sleep(30)
        if not click_next_page(page, pg + 1, prev_sig, expected_page_count=page_count):
            break
        pg += 1
        html = get_stable_content(page)
        rows, page_count, _, skipped, skipped_rows = parse_page(html, page.url)
        combo_skipped["few_cols"] += skipped["few_cols"]
        combo_skipped["no_name"] += skipped["no_name"]
        for sr in skipped_rows:
            sr["label"] = label
            all_skipped_rows.append(sr)
        prev_sig = get_first_row_signature(page)
        for r in rows:
            combo_seen_ids.add(r["id"])
            if r["id"] not in seen_ids:
                seen_ids.add(r["id"])
                all_results.append(r)
        print(f"  [{label}] {pg} / {page_count or pg} ページ (累計 {len(all_results)} 件)")

    if pg < page_count:
        print(f"  [{label}] 警告: {page_count}ページ中{pg}ページで打ち切られました（想定外の早期終了）")

    added = len(all_results) - before_count
    combo_total = len(combo_seen_ids)
    if combo_skipped["few_cols"] or combo_skipped["no_name"]:
        print(f"  [{label}] パース時にスキップされた行: 列数不足 {combo_skipped['few_cols']} 件, "
              f"科目名なし {combo_skipped['no_name']} 件")
    if total_hits:
        note = "" if combo_total == total_hits else f"  ← この条件のページングで{total_hits - combo_total}件読み取れていません"
        print(f"  [{label}] 検索結果 {total_hits} 件 → この条件で読み取り {combo_total} 件 (新規 {added} 件, 総計 {len(all_results)} 件){note}")


def skipped_rows_path_for(out_path: Path) -> Path:
    return out_path.with_name(out_path.stem + "_skipped_rows.json")


def scrape(*, bu: str, gkb: str, campuses: list[str], delay: float,
           state_path: Path, headless: bool, out_path: Path,
           keyword: str, class_name: str, teacher: str) -> None:
    all_results: list[dict] = load_existing_results(out_path)
    seen_ids: set[str] = {r["id"] for r in all_results}
    if all_results:
        print(f"前回までの保存分 {len(all_results)} 件を読み込みました（重複はIDで自動的に除外されます）。")

    skipped_rows_path = skipped_rows_path_for(out_path)
    all_skipped_rows: list[dict] = []

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=headless)
            context_kwargs = {}
            if state_path.exists():
                context_kwargs["storage_state"] = str(state_path)
            context = browser.new_context(**context_kwargs)
            page = context.new_page()

            ensure_logged_in(page, state_path)

            # 無条件（曜日・時限の絞り込みなし）で全体件数だけ確認する。
            # これは表示用の参考情報にすぎず、以降の56条件巡回には不要なので、
            # ここで失敗しても本題の巡回は続行する（無条件検索は最大件数のクエリで
            # サーバー応答が遅くなりやすく、タイムアウトで全体を止める価値がない）。
            print("=== 全体件数を確認 ===")
            grand_total: int | None = None
            try:
                run_search(page, bu=bu, gkb=gkb, campuses=campuses,
                           keyword=keyword, class_name=class_name, teacher=teacher)
                _, _, grand_total, _ = parse_page(get_stable_content(page), page.url)
                print(f"検索結果の総件数: {grand_total} 件")
            except Exception as e:  # noqa: BLE001
                print(f"  (全体件数の確認に失敗しましたが、巡回は続行します: {e})")

            # 全体件数確認（無条件・10,690件相当の最大クエリ）の直後は、サーバー側
            # またはUpdatePanelの描画が完全に落ち着く前に次の検索を打ってしまい、
            # 最初の1件目の条件だけが高確率でタイムアウトすることが分かっている。
            # ここで明示的に一呼吸置いて状態を安定させる。
            try:
                page.wait_for_load_state("networkidle")
            except Exception:  # noqa: BLE001
                pass
            time.sleep(3)

            # 「曜日」のみで分割して巡回する（時限側は未チェックのまま＝フィルタなし）。
            # 曜日×時限で両方を単一値に絞ると、複数時限にまたがる授業（例:
            # 3-4限連続の演習科目）が、単一時限を指定した検索条件にヒットせず、
            # 実装を変えても再現する約2,455件の取得漏れの原因になっていることが
            # 判明した（全曜日・全時限をチェック＝フィルタなし相当だと正しく
            # 10,690件返ることを確認済み）。時限側を未チェックのままにすることで、
            # この群は「フィルタなし」として扱われ、複数時限科目も正しく拾える。
            combos = [(d, None) for d in DAY_CHECKBOX_IDS]
            valid_labels = {f"{d}曜" for d in DAY_CHECKBOX_IDS}
            # 過去に別の分割方式（曜日×時限56分割など）で作られた進捗ファイルが
            # 残っていると、現在のラベル形式（例: "月曜"）と一致しない古いラベルが
            # 混ざるので、現在の分割方式に存在するラベルだけに絞り込む。
            completed_combos = load_completed_combos(out_path) & valid_labels
            if completed_combos:
                print(f"前回までに完走済みの条件 {len(completed_combos)}/{len(combos)} 件をスキップします。")
            failed_labels: list[str] = []

            for i, (day_label, period_label) in enumerate(combos, start=1):
                label = f"{day_label}曜"
                if label in completed_combos:
                    continue
                try:
                    crawl_one_search(
                        page, bu=bu, gkb=gkb, campuses=campuses,
                        keyword=keyword, class_name=class_name, teacher=teacher,
                        day_label=day_label, period_label=period_label,
                        delay=delay, seen_ids=seen_ids, all_results=all_results,
                        all_skipped_rows=all_skipped_rows, label=label,
                    )
                    completed_combos.add(label)
                except (Exception, KeyboardInterrupt) as e:
                    if isinstance(e, KeyboardInterrupt):
                        raise
                    # 1条件が失敗しても56条件全体を止めない。この条件は次回
                    # 未完走のまま残るので、再実行時にもう一度自動で試みられる。
                    print(f"  [{label}] この条件の巡回中にエラーが発生したためスキップします: {e}")
                    failed_labels.append(label)
                # 条件ごとに保存しておく（途中で止まっても直前の分まで確実に残る）
                save_results(all_results, out_path)
                save_completed_combos(out_path, completed_combos)
                save_results(all_skipped_rows, skipped_rows_path)
                if i % 8 == 0 or i == len(combos):
                    print(f"進捗: {i}/{len(combos)} 条件を巡回済み (累計 {len(all_results)} 件)")

            page.close()
            context.close()
            browser.close()

            if failed_labels:
                print(f"\n警告: 以下の {len(failed_labels)} 条件でエラーが発生しスキップされました: {', '.join(failed_labels)}")
                print("もう一度実行すると、これらの条件だけ自動的に再挑戦されます。")

            if grand_total is not None and len(all_results) < grand_total:
                print(f"\n警告: 検索結果は{grand_total}件のはずですが、取得できたのは{len(all_results)}件です。")
                print("もう一度実行すると、保存済みのログインセッションから再開できます（重複はIDで除外されます）。")
    except (Exception, KeyboardInterrupt) as e:
        if isinstance(e, KeyboardInterrupt):
            print("\n中断されました。")
        else:
            print(f"\nエラーが発生しました: {e}")
        if all_results:
            save_results(all_results, out_path)
            print(f"それまでに取得できた {len(all_results)} 件を {out_path} に保存しました（途中まで）。")
            print("もう一度実行すれば、保存済みのログインセッションから再開できます（重複はIDで除外されます）。")
        if all_skipped_rows:
            save_results(all_skipped_rows, skipped_rows_path)
        raise

    save_results(all_results, out_path)
    save_results(all_skipped_rows, skipped_rows_path)
    print(f"\n完了: {len(all_results)} 件を {out_path} に保存しました。")
    if all_skipped_rows:
        print(f"パースでスキップされた行 {len(all_skipped_rows)} 件を {skipped_rows_path} に保存しました。")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bu", default=BU_CHOICES["day"], help="設置区分 (既定: BU1=第一部/学部昼間)")
    ap.add_argument("--gkb", default="", help='学期コード (例: "1.1.12"=前期, "1.2.12"=後期, 空文字=すべて)')
    ap.add_argument("--campus", default="CP1,CP4", help="開講キャンパス (CP1=青山, CP4=相模原, カンマ区切り)")
    ap.add_argument("--keyword", default="", help="キーワード絞り込み (任意)")
    ap.add_argument("--class-name", dest="class_name", default="", help="科目名絞り込み (任意)")
    ap.add_argument("--teacher", default="", help="教員名絞り込み (任意)")
    ap.add_argument("--delay", type=float, default=2.0, help="各ページ送り間隔(秒)。短くしすぎないこと")
    ap.add_argument("--headless", action="store_true", help="ヘッドレスで実行 (初回ログイン時は使わないこと)")
    ap.add_argument("--state", default=str(DEFAULT_STATE_PATH), help="ログインセッション保存先")
    ap.add_argument("--out", default="scripts/output/syllabus_index.json", help="出力 JSON パス")
    args = ap.parse_args()

    campuses = [c.strip() for c in args.campus.split(",") if c.strip()]

    scrape(
        bu=args.bu,
        gkb=args.gkb,
        campuses=campuses,
        delay=args.delay,
        state_path=Path(args.state),
        headless=args.headless,
        out_path=Path(args.out),
        keyword=args.keyword,
        class_name=args.class_name,
        teacher=args.teacher,
    )


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n中断しました。")
        sys.exit(1)
