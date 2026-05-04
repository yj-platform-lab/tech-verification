# GitHub CI/CD Workflow

## 概要

GitHub ActionsおよびBranch Protectionを用いたPRベースの開発フローを検証する。

本検証では、CI/CD、レビュー、ブランチ制御など、リポジトリ単位で適用される設定を扱う。

## なぜ別リポジトリを使用するのか

tech-verificationリポジトリ内のディレクトリとして検証を行うことも可能であるが、以下の理由により専用の検証リポジトリを使用している。

- Branch Protectionはリポジトリ単位で適用される
- Required status checks（CI必須化）もリポジトリ単位
- delete branch on mergeもリポジトリ全体に影響する
- GitHub Actionsの挙動もリポジトリ単位で制御される

これらの設定を既存リポジトリに適用すると、他の検証や記事に影響を与えるため、専用のサンドボックス環境としてリポジトリを分離している。

## 実装リポジトリ

詳細な検証内容および実装は以下のリポジトリで管理している。

- actions-sandbox  
  GitHub Actions / Branch Protection / Terraformによるリポジトリ管理の検証環境

## 補足

本ディレクトリは「検証の背景・設計意図」を記録するためのものであり、実際の動作検証はactions-sandboxリポジトリで行う。