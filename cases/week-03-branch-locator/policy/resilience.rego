# Week 3 resilience checks: timeouts, retries with backoff, throttling, PITR.
#   conftest test --parser hcl2 --combine --all-namespaces --policy policy terraform/*.tf
# Package name = rubric category. Messages keep the [tag] prefix.
package resilience

import data.lib.addressed
import data.lib.blocks
import data.lib.resources
import rego.v1

# ---------------------------------------------------------------- DynamoDB --

# Point-in-time recovery is the RPO story for the branch table.
deny contains msg if {
	some [addr, t] in addressed("aws_dynamodb_table")
	not pitr_enabled(t)
	msg := sprintf("[resilience] DynamoDB table '%v' has no point_in_time_recovery { enabled = true } (no way back from a bad write/delete).", [addr])
}

pitr_enabled(t) if {
	some b in blocks(object.get(t, "point_in_time_recovery", []))
	b.enabled == true
}

# Lab trade-off, flagged so nobody copies it to production.
warn contains msg if {
	some [addr, t] in addressed("aws_dynamodb_table")
	object.get(t, "deletion_protection_enabled", false) != true
	msg := sprintf("[resilience] DynamoDB table '%v' has deletion_protection_enabled = false. OK in the lab (fast teardown); in production set true so one bad `terraform destroy` cannot delete the bank's data.", [addr])
}

# ------------------------------------------------------------- API Gateway --

# Stage throttling = load shedding at the front door.
deny contains msg if {
	some [addr, s] in addressed("aws_apigatewayv2_stage")
	not stage_throttled(s)
	msg := sprintf("[resilience] HTTP API stage '%v' has no default_route_settings throttling_rate_limit + throttling_burst_limit (a spike goes straight to Lambda/DynamoDB).", [addr])
}

stage_throttled(s) if {
	some b in blocks(object.get(s, "default_route_settings", []))
	b.throttling_rate_limit
	b.throttling_burst_limit
}

# REST API alternative: method settings throttling.
deny contains "[resilience] REST API has no stage throttling (aws_api_gateway_method_settings with throttling_rate_limit/burst_limit)." if {
	count(resources("aws_api_gateway_rest_api")) > 0
	count([m |
		some m in resources("aws_api_gateway_method_settings")
		some b in blocks(m.settings)
		b.throttling_rate_limit
	]) == 0
}

# The outer timeout must be explicit (and longer than Lambda's).
deny contains "[resilience] HTTP API integration has no explicit timeout_milliseconds (must be longer than the Lambda timeout)." if {
	some i in resources("aws_apigatewayv2_integration")
	not i.timeout_milliseconds
}

# ------------------------------------------------------------------ Lambda --

deny contains "[resilience] Lambda function has no explicit timeout." if {
	some fn in resources("aws_lambda_function")
	not fn.timeout
}

# The DynamoDB client must get explicit timeouts and bounded retries.
deny contains msg if {
	some fn in resources("aws_lambda_function")
	some key in ["DDB_CONNECT_TIMEOUT", "DDB_READ_TIMEOUT", "DDB_MAX_ATTEMPTS"]
	not fn.environment.variables[key]
	msg := sprintf("[resilience] Lambda environment is missing %v (client timeouts/retries must be explicit and reviewable).", [key])
}

# Reserved concurrency 0 = every request throttled.
deny contains "[resilience] Lambda reserved_concurrent_executions is hard-coded to 0 (all invocations throttled). Use the chaos variable instead." if {
	some fn in resources("aws_lambda_function")
	fn.reserved_concurrent_executions == 0
}
