# AWS / EC2 運用・障害対応 検証ログ

本リポジトリは、AWS EC2 を中心に  
**実際に手を動かして検証した運用・障害対応の記録**をまとめたものです。

## 検証テーマ
- VirtualBox仮想マシンをAWS EC2に移行する（./vbox-to-ec2-migration/README.md)
- EC2をSSM Managed Instanceに認識させる（./ec2-ssm-managed-instance/README.md)
- なぜ EC2 には VMware のようなリモートコンソールが見当たらないのか（./aws-ec2-connect-models/README.md)
- SSH / SSM 不可時のリカバリ手段
- 旧世代 EC2 からの移行検証（Xen → Nitro）
