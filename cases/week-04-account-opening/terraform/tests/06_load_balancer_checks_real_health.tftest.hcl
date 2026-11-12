# rubric: resilience
# Runs with `terraform test` - no AWS credentials needed (mocked provider).
# One check per file: the autograder scores each file separately.
# `command = apply` against a mock provider creates nothing real: Terraform
# just fills in fake IDs/ARNs so we can check how resources are wired.

mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = {
      id = "vpc-0123456789abcdef0"
    }
  }

  mock_data "aws_ec2_instance_type_offerings" {
    defaults = {
      locations = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_data "aws_subnets" {
    defaults = {
      ids = ["subnet-0aaa0000000000001", "subnet-0bbb0000000000002", "subnet-0ccc0000000000003"]
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      value          = "ami-0123456789abcdef0"
      insecure_value = "ami-0123456789abcdef0"
    }
  }

  mock_data "aws_iam_instance_profile" {
    defaults = {
      arn = "arn:aws:iam::123456789012:instance-profile/LabInstanceProfile"
    }
  }

  # Realistic ARNs so the provider's ARN validation accepts mocked values.
  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-east-1:123456789012:nnb-acct-grader-test-alerts"
    }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/nnb-acct-grader-test/50dc6c495c0c9188"
      arn_suffix = "app/nnb-acct-grader-test/50dc6c495c0c9188"
      dns_name   = "nnb-acct-grader-test-1234567890.us-east-1.elb.amazonaws.com"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/nnb-acct-grader-test/6d0ecf831eec9f09"
      arn_suffix = "targetgroup/nnb-acct-grader-test/6d0ecf831eec9f09"
    }
  }

  mock_resource "aws_launch_template" {
    defaults = {
      id             = "lt-0123456789abcdef0"
      latest_version = 1
    }
  }

  mock_resource "aws_security_group" {
    defaults = {
      id = "sg-0123456789abcdef0"
    }
  }

  mock_resource "aws_cloudwatch_metric_alarm" {
    defaults = {
      arn = "arn:aws:cloudwatch:us-east-1:123456789012:alarm:nnb-acct-grader-test"
    }
  }
}

variables {
  team_name = "grader-test"
}

run "load_balancer_checks_real_health" {
  command = apply

  assert {
    condition     = aws_lb_target_group.web.health_check[0].path == "/health"
    error_message = "The target group must probe /health (not /), which reports whether the app is really OK."
  }

  assert {
    condition     = aws_lb_target_group.web.health_check[0].interval <= 30 && aws_lb_target_group.web.health_check[0].unhealthy_threshold <= 3
    error_message = "Detect a dead instance within ~1.5 minutes: interval <= 30s and unhealthy_threshold <= 3."
  }

  assert {
    condition     = try(contains(tolist(aws_autoscaling_group.web.target_group_arns), aws_lb_target_group.web.arn), false)
    error_message = "Attach the Auto Scaling group to the target group (target_group_arns)."
  }
}
