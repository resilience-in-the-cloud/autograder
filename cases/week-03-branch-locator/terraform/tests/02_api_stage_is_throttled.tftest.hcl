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

run "api_stage_is_throttled" {
  command = plan

  assert {
    condition     = try(aws_apigatewayv2_stage.default.default_route_settings[0].throttling_rate_limit, 0) > 0
    error_message = "Set a stage throttling_rate_limit (default_route_settings) so a traffic spike is shed with 429s instead of overwhelming Lambda/DynamoDB."
  }

  assert {
    condition     = try(aws_apigatewayv2_stage.default.default_route_settings[0].throttling_burst_limit, 0) > 0
    error_message = "Set a stage throttling_burst_limit (default_route_settings)."
  }

  assert {
    condition     = try(length(aws_apigatewayv2_route.routes), 0) >= 3
    error_message = "Expose GET /health, GET /branches and GET /branches/{branch_id}."
  }
}
