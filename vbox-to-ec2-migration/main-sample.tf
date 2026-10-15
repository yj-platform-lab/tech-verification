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
