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

run "healthy_by_default" {
  command = plan

  assert {
    condition     = aws_lambda_function.balance.environment[0].variables["FAILURE_RATE"] == "0"
    error_message = "Do not ship with failure injection turned on."
  }
}
