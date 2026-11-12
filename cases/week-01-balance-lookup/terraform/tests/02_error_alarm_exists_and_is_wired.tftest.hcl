# rubric: observability
# Runs with `terraform test` - no AWS credentials needed (mocked provider).
# These are the checks the autograder uses for the technical rubric.

mock_provider "aws" {
  mock_data "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/LabRole"
    }
  }
}

variables {
  team_name = "grader-test"
}

run "error_alarm_exists_and_is_wired" {
  command = plan

  assert {
    condition     = aws_cloudwatch_metric_alarm.errors.metric_name == "Errors"
    error_message = "There must be a CloudWatch alarm on the Lambda Errors metric."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.errors.period <= 300
    error_message = "Error alarm period should be 5 minutes or less to detect failures quickly."
  }

  assert {
    condition     = try(length(aws_cloudwatch_metric_alarm.errors.alarm_actions), 0) > 0
    error_message = "The error alarm must notify someone (alarm_actions -> SNS topic)."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.errors.namespace == "AWS/Lambda" && try(aws_cloudwatch_metric_alarm.errors.dimensions["FunctionName"], "") == aws_lambda_function.balance.function_name && length(try(aws_cloudwatch_metric_alarm.errors.dimensions, {})) == 1
    error_message = "The errors alarm must watch THIS function: namespace AWS/Lambda, dimensions = { FunctionName = aws_lambda_function.balance.function_name } and no other dimension keys (an extra key points the alarm at a metric that doesn't exist)."
  }
}
