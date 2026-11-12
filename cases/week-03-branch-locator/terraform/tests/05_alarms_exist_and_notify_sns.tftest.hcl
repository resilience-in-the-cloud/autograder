# rubric: observability
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

run "alarms_exist_and_notify_sns" {
  # apply against the mock provider so ARNs are known and can be compared
  command = apply

  assert {
    condition     = aws_cloudwatch_metric_alarm.api_5xx.namespace == "AWS/ApiGateway" && aws_cloudwatch_metric_alarm.api_5xx.metric_name == "5xx"
    error_message = "There must be an alarm on the HTTP API '5xx' metric (namespace AWS/ApiGateway)."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.lambda_throttles.metric_name == "Throttles"
    error_message = "There must be an alarm on the Lambda 'Throttles' metric."
  }

  assert {
    condition = alltrue([
      for a in [aws_cloudwatch_metric_alarm.api_5xx, aws_cloudwatch_metric_alarm.lambda_throttles, aws_cloudwatch_metric_alarm.lambda_errors] :
      contains(try(a.alarm_actions, []), aws_sns_topic.alerts.arn) && a.period <= 300
    ])
    error_message = "5xx, throttle and error alarms must notify the SNS topic and use a period <= 5 minutes."
  }

  assert {
    condition     = try(aws_cloudwatch_metric_alarm.api_5xx.dimensions["ApiId"], "") == aws_apigatewayv2_api.branches.id && try(aws_cloudwatch_metric_alarm.api_5xx.dimensions["Stage"], "") == aws_apigatewayv2_stage.default.name && length(try(aws_cloudwatch_metric_alarm.api_5xx.dimensions, {})) == 2
    error_message = "The 5xx alarm must watch THIS API: dimensions ApiId = aws_apigatewayv2_api.branches.id and Stage = aws_apigatewayv2_stage.default.name and no other keys (use local.api_dimensions)."
  }

  assert {
    condition = alltrue([
      for a in [aws_cloudwatch_metric_alarm.lambda_throttles, aws_cloudwatch_metric_alarm.lambda_errors] :
      a.namespace == "AWS/Lambda" && try(a.dimensions["FunctionName"], "") == aws_lambda_function.branches.function_name && length(try(a.dimensions, {})) == 1
    ])
    error_message = "The throttle and error alarms must watch THIS function: namespace AWS/Lambda, FunctionName = aws_lambda_function.branches.function_name, and no other dimension keys."
  }
}
