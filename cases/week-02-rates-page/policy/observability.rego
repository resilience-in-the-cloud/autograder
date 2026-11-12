package observability

import data.lib.addressed
import data.lib.created
import data.lib.resources
import rego.v1

deny contains "[observability] No CloudWatch alarm on the CloudFront '5xxErrorRate' metric." if {
	count([a |
		some a in created("aws_cloudwatch_metric_alarm")
		a.metric_name == "5xxErrorRate"
	]) == 0
}

deny contains msg if {
	some [addr, a] in addressed("aws_cloudwatch_metric_alarm")
	not a.alarm_actions
	msg := sprintf("[observability] Alarm '%v' has no alarm_actions (nobody gets told).", [addr])
}

# CloudFront metrics only exist in us-east-1.
deny contains msg if {
	some [addr, a] in addressed("aws_cloudwatch_metric_alarm")
	a.namespace == "AWS/CloudFront"
	not a.provider
	msg := sprintf("[observability] Alarm '%v' must use a us-east-1 provider (e.g. provider = aws.global); CloudFront metrics are only published there.", [addr])
}

warn contains "[observability] No CloudWatch dashboard defined." if {
	count(resources("aws_cloudwatch_dashboard")) == 0
}
