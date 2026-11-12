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

run "latency_alarm_exists" {
  command = plan

  assert {
    condition     = aws_cloudwatch_metric_alarm.latency.metric_name == "Duration"
    error_message = "There must be a latency alarm on the Lambda Duration metric."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.latency.namespace == "AWS/Lambda" && try(aws_cloudwatch_metric_alarm.latency.dimensions["FunctionName"], "") == aws_lambda_function.balance.function_name && length(try(aws_cloudwatch_metric_alarm.latency.dimensions, {})) == 1
    error_message = "The latency alarm must watch THIS function: namespace AWS/Lambda, dimensions = { FunctionName = aws_lambda_function.balance.function_name } and no other dimension keys (an extra key points the alarm at a metric that doesn't exist)."
  }
}
