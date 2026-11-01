# Network and data-tier foundations for the CHA proof of concept (Listing K1 in the report).
# Compute, Aurora and the load balancer follow the same pattern and were built in the console.
# The "-tf" suffix avoids clashing with the console-built resources.
#
# Checkov skips below are deliberate. Each one names the reason and, where it is a
# known gap rather than a design choice, the production change that would close it.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

provider "aws" {
  region = var.region
}

# Network
resource "aws_vpc" "cha_vpc" {
  #checkov:skip=CKV2_AWS_11:Known PoC gap. Production enables VPC flow logs to the log-archive account.
  #checkov:skip=CKV2_AWS_12:Known PoC gap. Production replaces the default security group with a deny-all one.
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "cha-prod-vpc-tf" }
}

resource "aws_subnet" "cha_data_a" {
  vpc_id            = aws_vpc.cha_vpc.id
  cidr_block        = "10.0.64.0/24"
  availability_zone = "${var.region}a"
  tags              = { Name = "cha-data-a-tf" }
}

resource "aws_subnet" "cha_data_b" {
  vpc_id            = aws_vpc.cha_vpc.id
  cidr_block        = "10.0.65.0/24"
  availability_zone = "${var.region}b"
  tags              = { Name = "cha-data-b-tf" }
}

# Security groups (each admits traffic only from the tier before it)
resource "aws_security_group" "alb_sg" {
  #checkov:skip=CKV2_AWS_5:Attached to the console-built ALB, which Terraform does not manage.
  #checkov:skip=CKV_AWS_382:The ALB must reach the app tier, which sits behind NAT, so egress stays open.
  name        = "alb-sg-tf"
  description = "Allows inbound web traffic to the ALB"
  vpc_id      = aws_vpc.cha_vpc.id

  ingress {
    #checkov:skip=CKV_AWS_260:The PoC ALB listener is HTTP only because no domain was available for an ACM certificate. Production redirects port 80 to 443.
    description = "HTTP from the internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS from the internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  #trivy:ignore:AVD-AWS-0104:Same reason as CKV_AWS_382 on app_sg: the ALB reaches app tasks and health checks, so egress stays open.
  egress {
    description = "All outbound, to the app tier and health checks"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "app_sg" {
  #checkov:skip=CKV2_AWS_5:Attached to the console-built ECS tasks, which Terraform does not manage.
  #checkov:skip=CKV_AWS_382:App tasks call AWS APIs and external services through the NAT gateway, so egress stays open.
  name        = "app-sg-tf"
  description = "Allows inbound app traffic from the ALB only"
  vpc_id      = aws_vpc.cha_vpc.id

  ingress {
    description     = "App port from the ALB only"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  #trivy:ignore:AVD-AWS-0104:Same reason as CKV_AWS_382: app tasks reach AWS APIs and external services through NAT.
  egress {
    description = "All outbound, through NAT and the VPC endpoints"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db_sg" {
  #checkov:skip=CKV2_AWS_5:Attached to the console-built Aurora instances, which Terraform does not manage.
  #checkov:skip=CKV_AWS_382:Egress is not needed by the database, but the rule is kept to match the console-built PoC. Production removes it.
  name        = "db-sg-tf"
  description = "Allows inbound database traffic from the app tier only"
  vpc_id      = aws_vpc.cha_vpc.id

  ingress {
    description     = "MySQL from the app tier only"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app_sg.id]
  }
  #trivy:ignore:AVD-AWS-0104:Same reason as CKV_AWS_382 on db_sg: kept to match the console-built PoC. Production removes it.
  egress {
    description = "All outbound, kept to match the console-built PoC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Data tier
resource "aws_db_subnet_group" "cha" {
  name       = "cha-data-subnet-group-tf"
  subnet_ids = [aws_subnet.cha_data_a.id, aws_subnet.cha_data_b.id]
}

resource "aws_kms_key" "cha_data_key" {
  #checkov:skip=CKV2_AWS_64:The PoC uses the default key policy, which delegates to IAM. The report's separate admin and user policy is applied in the console.
  description         = "CHA data encryption key"
  enable_key_rotation = true
}

resource "aws_kms_alias" "cha_data_key" {
  name          = "alias/cha-data-key-tf"
  target_key_id = aws_kms_key.cha_data_key.key_id
}

resource "aws_dynamodb_table" "iot_vitals" {
  name         = "cha-iot-vitals-tf"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "deviceId"
  range_key    = "timestamp"

  attribute {
    name = "deviceId"
    type = "S"
  }
  attribute {
    name = "timestamp"
    type = "N"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.cha_data_key.arn
  }
}
