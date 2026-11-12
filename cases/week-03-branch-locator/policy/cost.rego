package cost

import data.lib.addressed
import data.lib.resources
import rego.v1

deny contains "[cost] Log group has no retention_in_days (logs kept forever)." if {
	some lg in resources("aws_cloudwatch_log_group")
	not lg.retention_in_days
}

# On-demand fits a small, spiky directory workload.
warn contains msg if {
	some [addr, t] in addressed("aws_dynamodb_table")
	object.get(t, "billing_mode", "PROVISIONED") != "PAY_PER_REQUEST"
	msg := sprintf("[cost] DynamoDB table '%v' is PROVISIONED: you pay for idle capacity and risk provisioned-throughput throttling. Justify it or use PAY_PER_REQUEST.", [addr])
}
