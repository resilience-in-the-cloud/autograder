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

run "dynamodb_client_has_timeouts_and_bounded_retries" {
  command = plan

  assert {
    condition     = can(tonumber(aws_lambda_function.branches.environment[0].variables["DDB_READ_TIMEOUT"])) && can(tonumber(aws_lambda_function.branches.environment[0].variables["DDB_CONNECT_TIMEOUT"]))
    error_message = "Pass DDB_CONNECT_TIMEOUT and DDB_READ_TIMEOUT to the function so the boto3 client never waits on default (60s) timeouts."
  }

  assert {
    condition     = tonumber(lookup(aws_lambda_function.branches.environment[0].variables, "DDB_MAX_ATTEMPTS", "0")) >= 2 && tonumber(lookup(aws_lambda_function.branches.environment[0].variables, "DDB_MAX_ATTEMPTS", "0")) <= 5
    error_message = "DDB_MAX_ATTEMPTS must be 2-5: retry transient errors, but bounded."
  }

  # Worst case before the client gives up: every attempt hits connect + read timeout,
  # plus botocore "standard" backoff between attempts (up to 1 s, 2 s, 4 s ... < 2^(attempts-1) s).
  assert {
    condition = (
      (tonumber(lookup(aws_lambda_function.branches.environment[0].variables, "DDB_CONNECT_TIMEOUT", "999")) +
      tonumber(lookup(aws_lambda_function.branches.environment[0].variables, "DDB_READ_TIMEOUT", "999"))) *
      tonumber(lookup(aws_lambda_function.branches.environment[0].variables, "DDB_MAX_ATTEMPTS", "999")) +
      pow(2, tonumber(lookup(aws_lambda_function.branches.environment[0].variables, "DDB_MAX_ATTEMPTS", "999")) - 1)
    ) < aws_lambda_function.branches.timeout
    error_message = "(connect_timeout + read_timeout) x max_attempts + 2^(max_attempts-1) s of backoff must fit inside the Lambda timeout (the retry budget must nest inside the caller's timeout)."
  }
}
