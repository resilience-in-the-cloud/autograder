# rubric: security
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

run "cloudfront_uses_oac_and_https" {
  # apply (against mocks) so the OAC id is known and we can check it is attached.
  command = apply

  assert {
    condition     = aws_cloudfront_origin_access_control.site.origin_access_control_origin_type == "s3" && aws_cloudfront_origin_access_control.site.signing_behavior == "always"
    error_message = "[security] Use an Origin Access Control (type s3, signing_behavior always)."
  }

  assert {
    condition     = alltrue([for o in aws_cloudfront_distribution.site.origin : o.origin_access_control_id == aws_cloudfront_origin_access_control.site.id])
    error_message = "[security] Every S3 origin must use the OAC (buckets stay private; only CloudFront can read)."
  }

  assert {
    condition     = contains(["redirect-to-https", "https-only"], aws_cloudfront_distribution.site.default_cache_behavior[0].viewer_protocol_policy)
    error_message = "[security] Viewers must use HTTPS (redirect-to-https or https-only)."
  }
}
