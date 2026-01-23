# EC2をSSM Managed Instanceに認識させる

## 背景
Amazon Linux 2023 を搭載した EC2 に対しSystems Manager Automation を用いた検証を行う中で、SSM Agent が標準インストールされているにもかかわらずManaged Instance として認識されない事象に直面した。

調査の結果、IAM ロール設定など複数の前提条件が必要であることが分かったため、本検証ではそれらを Terraform で整理する。

## 結論
Managed Instance として認識させるには、SSM Agent のインストールだけではなく、AmazonSSMManagedInstanceCore を付与した IAM ロールをインスタンスプロファイル経由で EC2 に関連付け、かつ SSM エンドポイントへのアウトバウンド通信が可能である必要がある。

これらの前提条件を満たすことで、Systems Manager Automation Runbook を正常に実行できることを確認した。


## この記事で分かること
- SSM Managed Instance に必要な IAM 構成
- Terraform での最小構成例
- SSM が利用するアウトバウンド通信要件


## 前提条件

- EC2 が Amazon Linux 2023 で起動していること
- Kernel: 6.x（AL2023 標準）
- EC2 へ SSH ログイン可能であること
- AWS CLI を実行できる環境
- Terraform の基本操作が可能であること
- EC2 の IAM ロール / SG を変更できる権限
- EC2 が Internet Gateway 経由で外部通信可能（今回の検証範囲）

## 手順

### Step0:環境構築

terraformで検証環境を用意する。使用したTerraform設定ファイルは以下。AMI IDは公式が提供しているIDを使用。

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
  default = "ssm-ready"
}

variable "environment" {
  type    = string
  default = "dev"
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
# Key Pair
# ---------------------------------------
resource "aws_key_pair" "ssh" {
  key_name   = "${var.project}-${var.environment}-keypair"
  public_key = file("./<公開鍵>")

  tags = {
    Name    = "${var.project}-${var.environment}-keypair"
    Project = var.project
    Env     = var.environment
  }
}

# ---------------------------------------
# EC2 Instance
# ---------------------------------------
resource "aws_instance" "ssmec2" {
  ami                         = "ami-09cd9fdbf26acc6b4"
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public_subnet_1a.id
  associate_public_ip_address = true
  vpc_security_group_ids = [aws_security_group.ssh_sg.id]
  key_name               = aws_key_pair.ssh.key_name

  tags = {
    Name    = "${var.project}-${var.environment}-ssmec2"
    Project = var.project
    Env     = var.environment
  }
}
```

### Step1:SSMに認識されていないことを確認

まずは以下のコマンドで当該インスタンスの情報が表示されないことを確認する。もしインスタンスの情報が表示されるようであれば今回の作業は不要

```bash
##SSM登録状況確認（実行結果にインスタンスの情報が表示されないことを確認する）
aws ssm describe-instance-information
```

### Step2:EC2にSSM Agentが存在することを確認

対象のEC2にSSMがインストールされているか確認する。コマンドの詳細は以下参照

参考：[https://docs.aws.amazon.com/ja_jp/systems-manager/latest/userguide/agent-install-rhel-7.html](https://docs.aws.amazon.com/ja_jp/systems-manager/latest/userguide/agent-install-rhel-7.html)

```bash
#SSM導入確認
systemctl status amazon-ssm-agent

#自動起動設定（enabledであることを確認）
systemctl is-enabled amazon-ssm-agent

#（上記が入っていない場合）SSM導入
sudo yum install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm
```

### Step3:EC2にIAMロールが付与されているか確認

以下のコマンドを実行し、対象の EC2 インスタンスに AmazonSSMManagedInstanceCore ポリシーを持つ IAM ロールが付与されているかを確認する。

参考:[https://docs.aws.amazon.com/ja_jp/systems-manager/latest/userguide/setup-instance-permissions.html](https://docs.aws.amazon.com/ja_jp/systems-manager/latest/userguide/setup-instance-permissions.html)

```bash
aws ec2 describe-instances \
  --instance-ids i-xxxxxxxxxxxxxxxxx \
  --query "Reservations[].Instances[].IamInstanceProfile"
```

初回構築直後のEC2では、AmazonSSMManagedInstanceCoreを付与したIAMロールが設定されていない場合が多い。その場合は、Terraformを用いて新たにIAMロールおよび関連リソースを作成する。ここで押さえておきたいポイントは、以下の 2 点である。

- IAMロールの作成時には **信頼ポリシー（AssumeRole ポリシー）の定義が必須**であることに注意。そのため後述のHCLの記載ではセクションを分けている。一方、カスタムIAM ポリシーの作成は必須ではなく、AWS管理ポリシーをアタッチするだけでもよい。
- 作成した IAMロールは**直接 EC2 にアタッチすることはできず**、必ず**インスタンスプロファイルを介して関連付ける必要がある**。

以下に、IAMロール、ポリシーのアタッチ、およびインスタンスプロファイルを作成する Terraform設定ファイルを示す。

```hcl
# ---------------------------------------
# IAM Role (Required) trust_poricy
# ---------------------------------------
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "ec2_ssm_role" {
  name               = "ec2_ssm_role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

# ---------------------------------------
# Attach the AmazonSSMManagedInstanceCore to Role
# ---------------------------------------
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_ssm_role.id
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ---------------------------------------
# Create Instance Profile
# ---------------------------------------
resource "aws_iam_instance_profile" "ssm_ec2_profile" {
  name = aws_iam_role.ec2_ssm_role.name
  role = aws_iam_role.ec2_ssm_role.name
}

```

インスタンスプロファイルを作成したら、EC2 リソース側にもその設定を追記する必要がある。

以下のiam_instance_profile行が追記箇所である。

```hcl
# ---------------------------------------
# EC2 Instance
# ---------------------------------------
resource "aws_instance" "ssmec2" {
  ami                         = "ami-09cd9fdbf26acc6b4"
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public_subnet_1a.id
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ssm_ec2_profile.name
  vpc_security_group_ids = [aws_security_group.ssh_sg.id]
  key_name               = aws_key_pair.ssh.key_name

  tags = {
    Name    = "${var.project}-${var.environment}-ssmec2"
    Project = var.project
    Env     = var.environment
  }
}

```

terraform applyが終わったら、再度以下のコマンドでInstanceProfileが設定されているか確認しよう。今度は上記で設定したInstanceProfileの設定が現れるはずである。

```bash
aws ec2 describe-instances \
  --instance-ids i-xxxxxxxxxxxxxxxxx \
  --query "Reservations[].Instances[].IamInstanceProfile"
```

### Step4:SSM へのアウトバウンド通信を確認

SSM Agentは、以下のAWSマネージドエンドポイントに対してアウトバウンド通信を行う。

- ssm.<region>.amazonaws.com
- ec2messages.<region>.amazonaws.com
- ssmmessages.<region>.amazonaws.com

参考：[https://docs.aws.amazon.com/ja_jp/systems-manager/latest/userguide/setup-create-vpc.html](https://docs.aws.amazon.com/ja_jp/systems-manager/latest/userguide/setup-create-vpc.html)

[https://docs.aws.amazon.com/ja_jp/prescriptive-guidance/latest/patterns/connect-to-an-amazon-ec2-instance-by-using-session-manager.html](https://docs.aws.amazon.com/ja_jp/prescriptive-guidance/latest/patterns/connect-to-an-amazon-ec2-instance-by-using-session-manager.html)

そのため、EC2がプライベートサブネットに配置されている場合は、上記エンドポイントに対応する VPC エンドポイントを作成する必要がある。

一方、今回のEC2はInternet Gatewayに接続されたVPC上に配置されているため、VPCエンドポイントの作成は不要である。

ただし、**EC2 が0.0.0.0/0宛にアウトバウンド通信できること**は前提条件となる。

そのため、当該インスタンスにアタッチされているセキュリティグループのアウトバウンドルールを以下のコマンドで確認する。

```bash
aws ec2 describe-security-groups \
  --group-ids sg-xxxxxxxx \
  --query "SecurityGroups[].IpPermissionsEgress"
```

この結果に0.0.0.0/0が含まれていれば問題ない。しかしTerraformで設定を行った場合、これらのアウトバンドルールは別途設定する必要がある。そのためstep0で記載した# Security Groupセクションに以下の内容を追記する

```hcl
resource "aws_security_group_rule" "allow_all_egress" {
  security_group_id = aws_security_group.ssh_sg.id
  type              = "egress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
}
```

再度以下を実行して、アウトバンドのルールが表示されたらStep4は完了。

```bash
aws ec2 describe-security-groups \
  --group-ids sg-xxxxxxxx \
  --query "SecurityGroups[].IpPermissionsEgress"
```

### Step5:SSMに認識されていることを確認

Step1で実行したコマンドを入力し、インスタンスの情報が表示されることを確認する。

```bash
##SSM登録状況確認
aws ssm describe-instance-information

##実行結果
{                                                                  
    "InstanceInformationList": [                                   
        {                                                          
            "InstanceId": "i-XXXXXXXXXXXXXXXX",                   
            "PingStatus": "Online",                                
            "LastPingDateTime": 1767181118.27,                     
            "AgentVersion": "3.3.3572.0",                          
            "IsLatestVersion": false,                              
            "PlatformType": "Linux",                               
            "PlatformName": "Red Hat Enterprise Linux Server",     
            "PlatformVersion": "7.2",                              
            "ResourceType": "EC2Instance",                         
            "IPAddress": "XXX.XXX.XXX.XXX",                          
            "ComputerName": "rheltest",                            
            "SourceId": "i-XXXXXXXXXXXXXXXXX",                     
            "SourceType": "AWS::EC2::Instance"                     
        }                                                          
    ]                                                              
}                                                                  
```

以上で完了
