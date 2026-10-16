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
