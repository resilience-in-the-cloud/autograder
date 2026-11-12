package observability

import data.lib.addressed
import data.lib.created
import data.lib.resources
import rego.v1

alarm_on(ns, metric) := [a |
	some a in created("aws_cloudwatch_metric_alarm")
	a.namespace == ns
	a.metric_name == metric
]

# Customer-facing errors.
deny contains "[observability] No CloudWatch alarm on the API Gateway '5xx' metric (HTTP API) / '5XXError' (REST API)." if {
	count(alarm_on("AWS/ApiGateway", "5xx")) + count(alarm_on("AWS/ApiGateway", "5XXError")) == 0
}

# Throttling must be visible.
deny contains "[observability] No CloudWatch alarm on the Lambda 'Throttles' metric." if {
	count(alarm_on("AWS/Lambda", "Throttles")) == 0
}

# Alarms must notify someone.
deny contains msg if {
	some [addr, a] in addressed("aws_cloudwatch_metric_alarm")
	count(object.get(a, "alarm_actions", [])) == 0
	msg := sprintf("[observability] Alarm '%v' has no alarm_actions (nobody gets told).", [addr])
}

# Access logs show 429s and integration errors per request.
warn contains msg if {
	some [addr, s] in addressed("aws_apigatewayv2_stage")
	not s.access_log_settings
	msg := sprintf("[observability] HTTP API stage '%v' has no access_log_settings.", [addr])
}

warn contains "[observability] No CloudWatch dashboard defined." if {
	count(resources("aws_cloudwatch_dashboard")) == 0
}
