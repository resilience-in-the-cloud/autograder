# rubric: iac-quality
# Runs with `terraform test` - no AWS credentials needed (mocked provider).
# These are the checks the autograder uses for the technical rubric.

mock_provider "aws" {
  mock_data "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/LabRole"
    }
  }

  # Realistic ARNs so `command = apply` against the mock passes provider validation.
  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-east-1:123456789012:nnb-branches-grader-test-alerts"
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:/mock"
    }
  }
  mock_resource "aws_dynamodb_table" {
    defaults = {
      arn = "arn:aws:dynamodb:us-east-1:123456789012:table/mock"
    }
  }
  mock_resource "aws_lambda_function" {
    defaults = {
      arn        = "arn:aws:lambda:us-east-1:123456789012:function:mock"
      invoke_arn = "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:123456789012:function:mock/invocations"
    }
  }
  mock_resource "aws_apigatewayv2_api" {
    defaults = {
      id            = "a1b2c3d4e5"
      api_endpoint  = "https://a1b2c3d4e5.execute-api.us-east-1.amazonaws.com"
      execution_arn = "arn:aws:execute-api:us-east-1:123456789012:a1b2c3d4e5"
    }
  }
  mock_resource "aws_cloudwatch_metric_alarm" {
    defaults = {
      arn = "arn:aws:cloudwatch:us-east-1:123456789012:alarm:mock"
    }
  }
}

variables {
  team_name = "grader-test"
}

run "chaos_knob_is_wired" {
  command = plan

  variables {
    reserved_concurrency = 0
  }

  assert {
    condition     = aws_lambda_function.branches.reserved_concurrent_executions == 0
    error_message = "reserved_concurrency variable must drive the Lambda's reserved_concurrent_executions (scripts/chaos.sh depends on it)."
  }
}

run "backend_chaos_knobs_are_wired" {
  command = plan

  variables {
    ddb_table_name_override = "nnb-branches-grader-test-does-not-exist"
    deny_backend_reads      = true
  }

  assert {
    condition     = aws_lambda_function.branches.environment[0].variables["TABLE_NAME"] == "nnb-branches-grader-test-does-not-exist"
    error_message = "ddb_table_name_override must drive the function's TABLE_NAME (scripts/chaos.sh backend-down depends on it)."
  }

  assert {
    condition     = length(aws_dynamodb_resource_policy.chaos_deny_reads) == 1
    error_message = "deny_backend_reads must create the deny resource policy (scripts/chaos.sh backend-deny depends on it)."
  }
}
