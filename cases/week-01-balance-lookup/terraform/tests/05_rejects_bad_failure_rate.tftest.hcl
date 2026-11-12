# rubric: iac-quality
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

run "rejects_bad_failure_rate" {
  command = plan

  variables {
    failure_rate = 2
  }

  expect_failures = [var.failure_rate]
}
