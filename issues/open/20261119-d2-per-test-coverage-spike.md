# D2 MoonBit per-test coverage capability spike

Status: open
Model: gpt-6.2-sol
Created: 2026-11-19
Updated: 2026-11-19
Branch: research/20261118-per-test-coverage-spike

## 概要

MoonBit 公式 coverage のテスト単位の帰属と短絡式の観測範囲を native / JS で調査する。

## 背景

[Mutation testing 品質プログラムの D2](../polished/20261117-mutation-testing-quality-program.md#d2-coveragetest-selection先にspike) の先行調査。
作業基点は `c86955f`。

## 問題

集約カウンターではテスト単位の到達性が不明で、行が実行されても同じ行の短絡式右辺が評価されたとは限らない。

## 目標

フルスイートの出力とテストを隔離して実行した場合の出力について、帰属可能な範囲と選別の可否を記録する。

## 対象外

ランタイム選別、計測の統合、変異判定や CI の変更、性能比較、親プログラム全体の完了。

## 提案する方針

公式 CLI と資料を確認し、名前付きテストと組み込み core QuickCheck を使う小さな fixture を作る。
native / JS のフルスイートと単独実行を、別々の出力先で計測する。

## 受け入れ条件

- [x] 両 target のツールバージョン、コマンド、出力形式と結果を再現可能に記録する。
- [x] フルスイート内の帰属、隔離実行の帰属、短絡行と右辺の観測を個別に判定する。
- [x] 欠落・陳腐化・target 不一致を選別の根拠にしない。未対応の範囲は no-go とする。

## テスト計画

- 依存同期なしで両 target の fixture を実行し、公式レポートと生出力を突き合わせる。
- 分析コードを追加する場合は対象を絞った単体テストを加える。
- ローカルイシューの検証と `git diff --check` を実行する。

## リスク

コンパイラ計測点と集約方法はバージョンと target に依存し、スイート内での共有状態や PBT の入力変更によって独立実行との同等性が崩れうる。

## 変更履歴

`CHANGELOG.md` impact: no

## 注記

研究用成果物は独立レビューの対象とする。

[調査結果と再現手順](../../docs/d2-per-test-coverage-spike.md)を記録した。
ネイティブの内部ドライバーで同期テストの区間を観測できたが、
両 target に共通する公式のテスト別 coverage 出力は確認できず、選別は no-go と判定した。
