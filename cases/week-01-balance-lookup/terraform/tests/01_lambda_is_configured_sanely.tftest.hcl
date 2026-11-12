# rubric: resilience
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

run "lambda_is_configured_sanely" {
  command = plan

  assert {
    condition     = aws_lambda_function.balance.timeout <= 10
    error_message = "Lambda timeout should be short (<= 10s) - a slow balance lookup is a failed one."
  }

  assert {
    condition     = aws_lambda_function.balance.runtime == "python3.12"
    error_message = "Use the python3.12 runtime."
  }

  assert {
    condition     = aws_cloudwatch_log_group.lambda.retention_in_days > 0
    error_message = "Set a log retention period (logs that live forever cost money)."
  }
}
