# rubric: resilience
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

run "timeouts_nest_correctly" {
  # apply (against the mock) so an unset timeout_milliseconds is a clear failure, not "unknown"
  command = apply

  assert {
    condition     = aws_lambda_function.branches.timeout <= 10
    error_message = "Lambda timeout should be short (<= 10s)."
  }

  assert {
    condition     = aws_lambda_function.branches.timeout * 1000 < aws_apigatewayv2_integration.lambda.timeout_milliseconds
    error_message = "Lambda timeout must be SHORTER than the API Gateway integration timeout, or API Gateway gives up while Lambda keeps working."
  }

  assert {
    condition     = aws_lambda_function.branches.runtime == "python3.12"
    error_message = "Use the python3.12 runtime."
  }
}
