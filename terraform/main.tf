# AI Gateway — reference IaC skeleton (Terraform)
# Maps the recruiter spec: VPC, least-privilege security groups, instance role
# (Bedrock invoke + Secrets Manager read only), secrets in Secrets Manager,
# HTTPS terminated at an ALB, gateway private behind it.
# This is a credible starting point, not a full landing zone — extend as needed.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

variable "region"        { default = "us-east-1" }
variable "corp_cidr"     { description = "CIDR allowed to reach the ALB (HTTPS)" type = string }
variable "acm_cert_arn"  { description = "ACM certificate ARN for the ALB HTTPS listener" type = string }

provider "aws" { region = var.region }

# ---------- network ----------
resource "aws_vpc" "gw" {
  cidr_block           = "10.40.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "ai-gateway" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.gw.id
  cidr_block        = cidrsubnet(aws_vpc.gw.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = { Name = "gw-private-${count.index}" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.gw.id
  cidr_block              = cidrsubnet(aws_vpc.gw.cidr_block, 8, 100 + count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = { Name = "gw-public-${count.index}" }
}

data "aws_availability_zones" "available" {}

# ---------- security groups (least privilege) ----------
resource "aws_security_group" "alb" {
  vpc_id = aws_vpc.gw.id
  ingress {
    description = "HTTPS from corporate network only"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.corp_cidr]
  }
  egress { from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "gateway" {
  vpc_id = aws_vpc.gw.id
  ingress {
    description     = "gateway port from the ALB only"
    from_port       = 4000
    to_port         = 4000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress { from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = ["0.0.0.0/0"] }
}

# ---------- secrets (nothing in user data, nothing in files) ----------
resource "aws_secretsmanager_secret" "gateway" {
  name = "ai-gateway/env"
}

# ---------- instance role: Bedrock invoke + read the one secret ----------
data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service", identifiers = ["ec2.amazonaws.com"] }
  }
}

resource "aws_iam_role" "gateway" {
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

data "aws_iam_policy_document" "gateway" {
  statement {
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = ["*"] # tighten to specific model ARNs in production
  }
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.gateway.arn]
  }
}

resource "aws_iam_role_policy" "gateway" {
  role   = aws_iam_role.gateway.id
  policy = data.aws_iam_policy_document.gateway.json
}

resource "aws_iam_instance_profile" "gateway" {
  role = aws_iam_role.gateway.name
}

# ---------- gateway host (single EC2 for the sprint; ECS/ASG is the HA path) ----------
resource "aws_instance" "gateway" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.large"
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.gateway.id]
  iam_instance_profile   = aws_iam_instance_profile.gateway.name
  user_data              = file("${path.module}/userdata.sh") # installs docker, pulls repo, compose up
  tags = { Name = "ai-gateway" }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# ---------- ALB: TLS terminates here; gateway stays private ----------
resource "aws_lb" "gw" {
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "gw" {
  port     = 4000
  protocol = "HTTP"
  vpc_id   = aws_vpc.gw.id
  health_check { path = "/health/liveliness" }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.gw.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.acm_cert_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gw.arn
  }
}

resource "aws_lb_target_group_attachment" "gw" {
  target_group_arn = aws_lb_target_group.gw.arn
  target_id        = aws_instance.gateway.id
}

output "gateway_url" { value = "https://${aws_lb.gw.dns_name}" }
