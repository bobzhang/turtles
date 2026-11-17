# mutation testingをPR運用に耐える品質改善ループにする

Status: open
Created: 2026-11-17
Updated: 2026-11-17
Branch: feat/diff-mutation-campaign-20261117
Priority: P0 (program)
Type: roadmap

## 目的

turtles.mbtを、単にmutation scoreを計算するツールから、MoonBitのPRレビューやcoding agentの修正ループで使える品質ゲートへ拡張する。

参照:
- [mizchi: mutation testingでテスト品質を評価する](https://zenn.dev/mizchi/articles/mutation-test-quality)
- [Google: State of Mutation Testing at Google](https://research.google/pubs/state-of-mutation-testing-at-google/)
- [mizchi/mutator](https://github.com/mizchi/mutator)
- [cargo-mutants diff selection](https://mutants.rs/in-diff.html)

mutation scoreだけを最適化しない。**判定の正しさ、実行コスト、指摘の有用性、再検証可能性**を独立して測る。

## 現状（main / 2026-11-17 README・実装確認）

- MoonBit native CLI、parser AST候補生成、比較・論理・算術・条件・boundary/body（opt-in）、target-aware discovery。
- baselineの二度実行、workspace隔離、並列jobs、timeout、`--affected` package-level test plan。
- schema 3 report、kill attribution、PBT witness/amplification、`--iterate` の安全側fingerprint。
- 変更行だけを選ぶdiff選択、test単位coverageによる選択、依存単位のcache、PR注釈は未実装または未確認。

## 既存課題との接続（重複実装しない）

- **P0: 検証済みdiffのchanged-line mutant選択**:
  [既存polished issue](../polished/20261013-diff-aware-mutation-selection.md) を実装する。
  既存仕様の `--in-diff FILE`（Git実行なし）、byte交差、new-side照合、schema 4、未実行数/空集合/target-inactiveの区別を維持する。
  `--since BASE` は、Git source selectionとworkerの責務を混ぜない後続ラッパーとして別PRに分ける。
- **P1: 増分cache**:
  function/test/manifest/toolchain/target単位の依存関係を導入する。
  変更検出の衝突・過小失効を避け、完全実行とのverdict一致を最優先する。
- **P2: test単位selection**:
  Moon公式coverageとtest実行指定が十分な証拠を与えるか調べ、`--affected` のpackage単位選択と比較する。
  coverageが欠落/古い/不一致なら広いoracleへ戻す。
- **P3: actionable findings**:
  arid/equivalent/untestedを混同せず分離し、理由付きaccept、survivorの最小再現、重要度、code-deletion候補を検討する。
  自動分類は証拠の有無を明示する。
- **P4: PR/Agent integration**:
  GitHub Checks、`--only mutant-id`、JSONレポートのstable ID、時間予算、選別優先度。
  PR単位のsubset scoreを全体のmutation coverageと表示しない。

## 最初の実装PRの受け入れ条件

以下の実装はこのroadmap PRには含めず、既存polished issueで要求済みの契約を採用する。

1. `--in-diff` がnew側行とmutationのbyte spanで正しく交差する。body変異を開始行だけで判定しない。
2. UTF-8、quoted Git path、rename、追加/削除、multiple hunks、CRLF、EOF、空diff、不正diff/古いcontextを区別する。読み込めない/不一致はexit 2。
3. `--list` と実行で同じcandidate集合を使い、target-inactive、diff-excluded、classifiedの区分を失わない。
4. 既存のworking tree隔離・baseline・timeout・`--iterate` の安全性を維持し、全件実行とsubsetの共通mutant verdictが一致する。
5. schema 4への移行と既存report consumerへの影響を明示する。
6. `moon fmt --check`、`moon check --target native --deny-warn`、`moon test --target native`、fixture E2E、native/js/allを証拠としてPRに記録する。

## 品質評価

| 指標 | 測定 | 合格判断 |
| --- | --- | --- |
| Verdict correctness | subset/最適化とfull runの共通mutant比較 | 不一致0件 |
| Performance | cold / unchanged / one-line diff のwall timeと起動回数 | 数値を記録して改善する（最初は固定目標なし） |
| Actionability | 人が評価したactionable指摘/評価された指摘 | 有用性の実測値を公開し、Google研究の75%を参考とする |
| Regression prevention | 以前のkillの喪失、新規survivor、flaky判定 | 判定と根拠を報告する |

`gpui.mbt` など実際のMoonBitモジュールの規模別評価を行う。full runとPR差分キャンペーンを別の分母で表示する。

## 非目標

- このroadmap単体で実装済み機能やテストPASSを主張しない。
- `--since` を既存の `--in-diff` 契約の代わりに先行実装しない。
- Proof companionの`PROVED`をmutation KILLEDへ合算しない。
- 自動でmainへmergeしない。

## 状態 / 検証

2026-11-17: 検討事項の文書化。GitHub Issuesはこのrepositoryで無効（create issue API HTTP 410）のため、既存のrepository-managed `issues/open` 規約で追跡。
実装変更・`moon` 実行・CI確認はこのIssue作成時点では未実施。
