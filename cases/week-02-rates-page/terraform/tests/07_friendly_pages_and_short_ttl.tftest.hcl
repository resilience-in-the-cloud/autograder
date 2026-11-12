# rubric: resilience
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

run "friendly_pages_and_short_ttl" {
  command = plan

  assert {
    condition     = aws_cloudfront_distribution.site.default_root_object == "index.html"
    error_message = "[resilience] Set default_root_object = \"index.html\" (otherwise / returns an S3 error)."
  }

  assert {
    condition     = contains([for e in aws_cloudfront_distribution.site.custom_error_response : e.error_code], 404)
    error_message = "[resilience] Add a custom_error_response for 404 (branded not-found page)."
  }

  assert {
    condition     = length([for e in aws_cloudfront_distribution.site.custom_error_response : e if e.error_code >= 500 || e.error_code == 403]) > 0
    error_message = "[resilience] Add a custom_error_response that shows a maintenance page when both origins fail."
  }

  assert {
    condition     = aws_cloudfront_cache_policy.site.default_ttl <= 300
    error_message = "[resilience] default_ttl <= 300s: stale rates (or a cached error) must not linger for hours."
  }
}
