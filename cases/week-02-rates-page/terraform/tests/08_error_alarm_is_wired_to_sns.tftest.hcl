# rubric: observability
# Runs with `terraform test` - no AWS credentials needed (mocked providers).
# One check per file; the autograder scores each file separately.

# Mock defaults give computed attributes realistic shapes (the provider
# validates ARNs, so random strings are not good enough).
mock_provider "aws" {
  mock_resource "aws_s3_bucket" {
    defaults = {
      arn                         = "arn:aws:s3:::nnb-rates-grader-test-x-0001"
      bucket                      = "nnb-rates-grader-test-x-0001"
      bucket_regional_domain_name = "nnb-rates-grader-test-x-0001.s3.us-east-1.amazonaws.com"
    }
  }
  mock_data "aws_cloudfront_response_headers_policy" {
    defaults = {
      id = "67f7725c-6f97-4210-82d7-5512b31e9d03"
    }
  }
  mock_resource "aws_cloudfront_distribution" {
    defaults = {
      id          = "E2MOCKDIST0001"
      arn         = "arn:aws:cloudfront::123456789012:distribution/E2MOCKDIST0001"
      domain_name = "d111111abcdef8.cloudfront.net"
    }
  }
}

# Monitoring lives in us-east-1 via the aliased provider (CloudFront metrics).
mock_provider "aws" {
  alias = "global"

  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-east-1:123456789012:nnb-rates-grader-test-alerts"
    }
  }
  mock_resource "aws_cloudwatch_metric_alarm" {
    defaults = {
      arn = "arn:aws:cloudwatch:us-east-1:123456789012:alarm:nnb-rates-grader-test"
    }
  }
}

variables {
  team_name = "grader-test"
}

run "error_alarm_is_wired_to_sns" {
  # apply against the mock so the distribution ID is known and can be compared
  command = apply

  assert {
    condition     = aws_cloudwatch_metric_alarm.cdn_5xx.namespace == "AWS/CloudFront" && aws_cloudwatch_metric_alarm.cdn_5xx.metric_name == "5xxErrorRate"
    error_message = "[observability] There must be an alarm on the CloudFront 5xxErrorRate metric."
  }

  assert {
    condition     = try(aws_cloudwatch_metric_alarm.cdn_5xx.dimensions["Region"], "") == "Global"
    error_message = "[observability] CloudFront metrics use the dimension Region = \"Global\"."
  }

  assert {
    condition     = try(length(aws_cloudwatch_metric_alarm.cdn_5xx.alarm_actions), 0) > 0 && aws_cloudwatch_metric_alarm.cdn_5xx.period <= 300
    error_message = "[observability] The 5xx alarm must notify an SNS topic and use a period of 5 minutes or less."
  }

  assert {
    condition     = try(aws_cloudwatch_metric_alarm.cdn_5xx.dimensions["DistributionId"], "") == aws_cloudfront_distribution.site.id && length(try(aws_cloudwatch_metric_alarm.cdn_5xx.dimensions, {})) == 2
    error_message = "[observability] The 5xx alarm must watch THIS distribution: DistributionId = aws_cloudfront_distribution.site.id and Region = \"Global\", no other keys."
  }
}
