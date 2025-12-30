# VirtualBox 仮想マシンをAWS EC2に移行する検証

## 検証の背景
2025/12現在、RHEL7はすでにサポートが終了しているが、依然として多くの既存システムで稼働しており、短期間でのOSアップデートが難しいケースが多い。
そこで、RHEL7環境を維持したままVirtualBox上の仮想マシンをAmazon EC2に移行する手順を検証する。本検証では、VM Import/Export機能を利用し、VirtualBoxのRHEL7仮想マシンをAMI化して EC2上で再現するまでの流れを確認する。


## 前提条件
- Terraform の基本操作に慣れていること
- VirtualBox 上で動作する RHEL7 仮想マシンが存在すること
    - OSはRed Hat Enterprise Linux 7.2
    - VirtualBoxのバージョンは7.0
    - SSH ログイン可能であること
- AWS CLI / IAM 権限を利用できる環境であること
- AMI インポート用の S3 バケットおよび IAM ロールが作成可能であること


## 全体の流れ
以下の流れで検証を行う
 - フェーズ1:Terraformで基盤を構築
 - フェーズ2:AWS CLIでVMをAMI化
 - フェーズ3:TerraformでEC2を作成

詳細の手順は以下参照。
[https://docs.aws.amazon.com/ja_jp/vm-import/latest/userguide/what-is-vmimport.html](https://docs.aws.amazon.com/ja_jp/vm-import/latest/userguide/what-is-vmimport.html)

### フェーズ1: Terraformで基盤を構築
Terraformで以下のリソースをまとめて構築する。
- S3バケット（VM Import用）
- IAMロール（VM Import用）
- VPC
- Subnet（Public）
- Internet Gateway
- Route Table + Association
- Security Group

なぜ IAM ロールを作成する必要があるのか。

それは後述する aws ec2 import-image によるAMI変換処理が、CLIを実行したユーザではなくAWSの VM Import/Exportサービスによって実行されるためである。

そのため、S3 上の OVA にアクセスする権限をAWSサービスへ委譲する必要があり、VM Import 用の IAMロールを事前に作成する必要がある。では以下のmain.tfファイルを使用し、VM Import/Export に必要なリソースを作成する。

main.tf

```hcl
# ---------------------------------------                                                                                  
# Terraform configuration                                                                                                  
# ---------------------------------------                                                                                  
terraform {                                                                                                                
  required_providers {                                                                                                     
    aws = {                                                                                                                
      source  = "hashicorp/aws"                                                                                            
      version = "~>6.0"                                                                                                    
    }                                                                                                                      
  }                                                                                                                        
}                                                                                                                          
                                                                                                                           
provider "aws" {                                                                                                           
  region = "ap-northeast-1"                                                                                                
}                                                                                                                          
                                                                                                                           
# ---------------------------------------                                                                                  
# Variables                                                                                                                
# ---------------------------------------                                                                                  
variable "project" {                                                                                                       
  type    = string                                                                                                         
  default = "vmimport-demo"                                                                                                
}                                                                                                                          
                                                                                                                           
variable "environment" {                                                                                                   
  type    = string                                                                                                         
  default = "dev"                                                                                                          
}                                                                                                                          
                                                                                                                           
# ---------------------------------------                                                                                  
# S3 bucket                                                                                                                
# ---------------------------------------                                                                                  
resource "random_string" "s3_unique_key" {                                                                                 
  length  = 6                                                                                                              
  upper   = false                                                                                                          
  lower   = true                                                                                                           
  numeric = true                                                                                                           
  special = false                                                                                                          
}                                                                                                                          
                                                                                                                           
resource "aws_s3_bucket" "s3_deploy_bucket" {                                                                              
  bucket = "${var.project}-${var.environment}-bucket-${random_string.s3_unique_key.result}"                                
}                                                                                                                          
                                                                                                                           
resource "aws_s3_bucket_public_access_block" "s3_deploy_bucket" {                                                          
  bucket                  = aws_s3_bucket.s3_deploy_bucket.id                                                              
  block_public_acls       = true                                                                                           
  block_public_policy     = true                                                                                           
  ignore_public_acls      = true                                                                                           
  restrict_public_buckets = true                                                                                           
}                                                                                                                          
                                                                                                                           
                                                                                                                           
# ---------------------------------------                                                                                  
# VPC / Subnet / Route / IGW                                                                                               
# ---------------------------------------                                                                                  
resource "aws_vpc" "vpc" {                                                                                                 
  cidr_block = "192.168.0.0/20"                                                                                            
                                                                                                                           
  tags = {                                                                                                                 
    Name    = "${var.project}-${var.environment}-vpc"                                                                      
    Project = var.project                                                                                                  
    Env     = var.environment                                                                                              
  }                                                                                                                        
}                                                                                                                          
                                                                                                                           
resource "aws_subnet" "public_subnet_1a" {                                                                                 
  vpc_id                  = aws_vpc.vpc.id                                                                                 
  cidr_block              = "192.168.1.0/24"                                                                               
  availability_zone       = "ap-northeast-1a"                                                                              
  map_public_ip_on_launch = true                                                                                           
                                                                                                                           
  tags = {                                                                                                                 
    Name    = "${var.project}-${var.environment}-public-subnet-1a"                                                         
    Project = var.project                                                                                                  
    Env     = var.environment                                                                                              
    type    = "public"                                                                                                     
  }                                                                                                                        
}                                                                                                                          
                                                                                                                           
resource "aws_route_table" "public_rt" {                                                                                   
  vpc_id = aws_vpc.vpc.id                                                                                                  
                                                                                                                           
  tags = {                                                                                                                 
    Name    = "${var.project}-${var.environment}-public-rt"                                                                
    Project = var.project                                                                                                  
    Env     = var.environment                                                                                              
    type    = "public"                                                                                                     
  }                                                                                                                        
}                                                                                                                          
                                                                                                                           
resource "aws_route_table_association" "public-rt-1a" {                                                                    
  route_table_id = aws_route_table.public_rt.id                                                                            
  subnet_id      = aws_subnet.public_subnet_1a.id                                                                          
}                                                                                                                          
                                                                                                                           
resource "aws_internet_gateway" "igw" {                                                                                    
  vpc_id = aws_vpc.vpc.id                                                                                                  
                                                                                                                           
  tags = {                                                                                                                 
    Name    = "${var.project}-${var.environment}-igw"                                                                      
    Project = var.project                                                                                                  
    Env     = var.environment                                                                                              
  }                                                                                                                        
}                                                                                                                          
                                                                                                                           
resource "aws_route" "public_rt_igw_r" {                                                                                   
  route_table_id         = aws_route_table.public_rt.id                                                                    
  destination_cidr_block = "0.0.0.0/0"                                                                                     
                                                                                                                           
  gateway_id = aws_internet_gateway.igw.id                                                                                 
}                                                                                                                          
                                                                                                                           
# ---------------------------------------                                                                                  
# Security Group                                                                                                           
# ---------------------------------------                                                                                  
resource "aws_security_group" "ssh_sg" {                                                                                   
  name        = "${var.project}-${var.environment}-ssh-sg"                                                                 
  description = "ssh security group"                                                                                       
  vpc_id      = aws_vpc.vpc.id                                                                                             
                                                                                                                           
  tags = {                                                                                                                 
    Name    = "${var.project}-${var.environment}-ssh-sg"                                                                   
    Project = var.project                                                                                                  
    Env     = var.environment                                                                                              
  }                                                                                                                        
}                                                                                                                          
                                                                                                                           
resource "aws_security_group_rule" "ssh_in" {                                                                              
  security_group_id = aws_security_group.ssh_sg.id                                                                         
  type              = "ingress"                                                                                            
  protocol          = "tcp"                                                                                                
  from_port         = 22                                                                                                   
  to_port           = 22                                                                                                   
  cidr_blocks       = ["0.0.0.0/0"]                                                                                        
}                                                                                                                          
                                                                                                                           
# ---------------------------------------                                                                                  
# IAM Role (trust policy + permissions)                                                                                    
# ---------------------------------------                                                                                  
data "aws_iam_policy_document" "vmimport_trust" {                                                                          
  statement {                                                                                                              
    effect = "Allow"                                                                                                       
                                                                                                                           
    principals {                                                                                                           
      type        = "Service"                                                                                              
      identifiers = ["vmie.amazonaws.com"]                                                                                 
    }                                                                                                                      
                                                                                                                           
    actions = ["sts:AssumeRole"]                                                                                           
                                                                                                                           
    condition {                                                                                                            
      test     = "StringEquals"                                                                                            
      variable = "sts:Externalid"                                                                                          
      values   = ["vmimport"]                                                                                              
    }                                                                                                                      
  }                                                                                                                        
}                                                                                                                          
                                                                                                                           
resource "aws_iam_role" "vmimport" {                                                                                       
  name               = "vmimport"                                                                                          
  assume_role_policy = data.aws_iam_policy_document.vmimport_trust.json                                                    
}                                                                                                                          
                                                                                                                           
                                                                                                                           
data "aws_iam_policy_document" "vmimport_role_policy" {                                                                    
  statement {                                                                                                              
    effect = "Allow"                                                                                                       
    actions = [                                                                                                            
      "s3:GetBucketLocation",                                                                                              
      "s3:GetObject",                                                                                                      
      "s3:ListBucket"                                                                                                      
    ]                                                                                                                      
    resources = [                                                                                                          
      aws_s3_bucket.s3_deploy_bucket.arn,                                                                                  
      "${aws_s3_bucket.s3_deploy_bucket.arn}/*"                                                                            
    ]                                                                                                                      
  }                                                                                                                        
                                                                                                                           
  statement {                                                                                                              
    effect = "Allow"                                                                                                       
    actions = [                                                                                                            
      "ec2:ModifySnapshotAttribute",                                                                                       
      "ec2:CopySnapshot",                                                                                                  
      "ec2:RegisterImage",                                                                                                 
      "ec2:Describe*"                                                                                                      
    ]                                                                                                                      
    resources = ["*"]                                                                                                      
  }                                                                                                                        
}                                                                                                                          
                                                                                                                           
resource "aws_iam_role_policy" "vmimport" {                                                                                
  name   = "vmimport"                                                                                                      
  role   = aws_iam_role.vmimport.id                                                                                        
  policy = data.aws_iam_policy_document.vmimport_role_policy.json                                                          
}         
```

（IAMのユーザ権限の詳細は以下参照）
[https://docs.aws.amazon.com/ja_jp/vm-import/latest/userguide/required-permissions.html](https://docs.aws.amazon.com/ja_jp/vm-import/latest/userguide/required-permissions.html)

### フェーズ2: AWS CLIでVMをAMI化

大前提として、ローカルPCからVirtualBox上の仮想マシンへSSH接続できることを事前に確認しておくこと。

本手順では、VirtualBox上の仮想マシンをOVAファイルとしてエクスポートし、そのOVAをEC2にインポートする。
そのため、EC2にSSH接続する際の「接続元」となるローカルPC上で、あらかじめSSH鍵を作成しておく必要がある。まずは以下のコマンドでSSH鍵を生成。

```bash
#鍵生成
ssh-keygen -t ed25519 -f vmimport-key
```

上記で作成されるvmimport-key.pubキーをVirtualBox上の仮想マシンに移行。

```bash
#鍵移行
mkdir -p ~/.ssh
cat vmimport-key.pub >> /home/<ユーザ名>/.ssh/authorized_keys
chown -R <ユーザ名>:<ユーザ名> /home/<ユーザ名>/.ssh
chmod 700 /home/<ユーザ名>/.ssh
chmod 600 /home/<ユーザ名>/.ssh/authorized_keys
```

ローカルPCから鍵を指定してSSH接続できるか確認。

```bash
#パスワードを聞かれずにログインできること
ssh -i vmimport-key <ユーザ名>@<ipアドレス>
```

上記を確認できたら、VirtualBox上の仮想マシンをシャットダウンする。その後ovaファイルをエクスポートし、それをフェーズ1で作成したs3に取り込む。

VirtualBoxを開きファイル→「仮想アプライアンスのエクスポート」を選択し、対象の仮想マシンを選択

![image1.png](./images/image1.png)

フォーマットの設定はovaファイルとする。[完了]を選択し、ovaファイルをエクスポート。

![image2.png](./images/image2.png)

指定したフォルダにovaファイルが生成されていることを確認。

では以下のコマンドでovaファイルをフェーズ1で作成したs3に取り込む

```bash
#S3バケット一覧を表示
aws s3 ls

#フェーズ1で作成したs3にインポート
aws s3 cp rhel72.ova s3://<フェーズ1で作成したs3>

#ovaファイルがエクスポートされていることを確認
aws s3 ls <フェーズ1で作成したs3>
```

次にS3 に置いた仮想マシンイメージを、aws ec2 import-imageでAMIに変換。

```bash
#S3に置いたovaをAMIに変換
aws ec2 import-image \
    --description "$(date '+%b %d %H:%M') RHEL7.2" \
    --disk-containers '[{
    "Format": "OVA",
    "UserBucket": {
      "S3Bucket": "<s3バケット名>",
      "S3Key": "rhel72.ova"
    }
  }]' 

#状態確認（"Status"が"completed"になるまで待つ。今回の検証では15分くらいかかった）
aws ec2 describe-import-image-tasks

#StatusがCompletedになったらImageIDを取得
aws ec2 describe-images --owner self
```

### フェーズ3: TerraformでEC2を作成

フェーズ2でVM ImportによりAMIを作成したが、このAMIはAWS CLIで作成されているため、Terraformでは直接管理されていない。そのため、EC2 インスタンスをTerraformで作成する前に、対象となる AMI を特定するための情報（Name / root-device-type / virtualization-type）を確認する必要がある。

```bash
#フェーズ2のコマンドで取得したImageIDを使用して以下のコマンドを実行
aws ec2 describe-images --image-ids <フェーズ2のコマンドで取得したImageID>
```

上記でnameとroot-device-typeとvirtualization-typeを取得後、main.tfに以下を追加。

```hcl
# ---------------------------------------
# AMI Data Source
# ---------------------------------------
data "aws_ami" "imported" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "name"
    values = ["<各AMIの値>"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
```

生成されたpubファイルをkaypairとしてmain.tfに追加。

```hcl
# ---------------------------------------
# Key Pair
# ---------------------------------------
resource "aws_key_pair" "ssh" {
  key_name   = "${var.project}-${var.environment}-keypair"
  public_key = file("./vmimport-key.pub")

  tags = {
    Name    = "${var.project}-${var.environment}-keypair"
    Project = var.project
    Env     = var.environment
  }
}
```

[AMI Data Source]の情報をもとに、EC2を作成。

```hcl
# ---------------------------------------
# EC2 Instance
# ---------------------------------------
resource "aws_instance" "imported" {
  ami                         = data.aws_ami.imported.id
  instance_type               = "c4.large"
  subnet_id                   = aws_subnet.public_subnet_1a.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.ssh_sg.id]
  key_name                    = aws_key_pair.ssh.key_name

  tags = {
    Name    = "${var.project}-${var.environment}-imported"
    Project = var.project
    Env     = var.environment
  }
}
```

terraform applyコマンドで上記を実行。実行後、EC2の作成情報を確認

```bash
#今terraform applyしたEC2のインスタンスIDを取得
aws ec2 describe-instances \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text

#作成状況を確認
aws ec2 describe-instance-status --instance-ids <インスタンスID>
```

SSHで接続できるか検証。

```bash
#パスワードを聞かれずにログインできること
ssh -i vmimport-key <ユーザ名>@<ipアドレス>
```

SSHで接続できれば完了。
