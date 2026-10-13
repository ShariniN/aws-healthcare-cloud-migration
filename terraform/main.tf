# Network and data-tier foundations for the CHA proof of concept (Listing K1 in the report).
# Compute, Aurora and the load balancer follow the same pattern and were built in the console.
# The "-tf" suffix avoids clashing with the console-built resources.

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
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "cha-prod-vpc-tf" }
}

resource "aws_subnet" "cha_data_a" {
  vpc_id            = aws_vpc.cha_vpc.id
  cidr_block        = "10.0.64.0/24"
  availability_zone = "${var.region}a"
  tags = { Name = "cha-data-a-tf" }
}

resource "aws_subnet" "cha_data_b" {
  vpc_id            = aws_vpc.cha_vpc.id
  cidr_block        = "10.0.65.0/24"
  availability_zone = "${var.region}b"
  tags = { Name = "cha-data-b-tf" }
}

# Security groups (each admits traffic only from the tier before it)
resource "aws_security_group" "alb_sg" {
  name        = "alb-sg-tf"
  description = "Allows inbound web traffic to the ALB"
  vpc_id      = aws_vpc.cha_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "app_sg" {
  name        = "app-sg-tf"
  description = "Allows inbound app traffic from the ALB only"
  vpc_id      = aws_vpc.cha_vpc.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db_sg" {
  name        = "db-sg-tf"
  description = "Allows inbound database traffic from the app tier only"
  vpc_id      = aws_vpc.cha_vpc.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app_sg.id]
  }
  egress {
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

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.cha_data_key.arn
  }
}
