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

run "throttle_alarm_exists" {
  command = plan

  assert {
    condition     = aws_cloudwatch_metric_alarm.throttles.metric_name == "Throttles"
    error_message = "Add a CloudWatch alarm on the Lambda Throttles metric (week 1 assignment)."
  }

  assert {
    condition     = try(length(aws_cloudwatch_metric_alarm.throttles.alarm_actions), 0) > 0
    error_message = "The throttles alarm must notify the SNS topic."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.throttles.namespace == "AWS/Lambda" && try(aws_cloudwatch_metric_alarm.throttles.dimensions["FunctionName"], "") == aws_lambda_function.balance.function_name && length(try(aws_cloudwatch_metric_alarm.throttles.dimensions, {})) == 1
    error_message = "The throttles alarm must watch THIS function: namespace AWS/Lambda, dimensions = { FunctionName = aws_lambda_function.balance.function_name } and no other dimension keys (an extra key points the alarm at a metric that doesn't exist)."
  }
}
