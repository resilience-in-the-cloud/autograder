# Week 1 observability checks. Package name = rubric category.
#   conftest test --parser hcl2 --combine --all-namespaces --policy policy terraform/
package observability

import data.lib.addressed
import data.lib.created
import data.lib.resources
import rego.v1

deny contains "[observability] No CloudWatch alarm on the Lambda 'Errors' metric." if {
	count([a | some a in created("aws_cloudwatch_metric_alarm"); a.metric_name == "Errors"]) == 0
}

deny contains "[observability] No CloudWatch alarm on the Lambda 'Duration' (latency) metric." if {
	count([a | some a in created("aws_cloudwatch_metric_alarm"); a.metric_name == "Duration"]) == 0
}

deny contains "[observability] No CloudWatch alarm on the Lambda 'Throttles' metric." if {
	count([a | some a in created("aws_cloudwatch_metric_alarm"); a.metric_name == "Throttles"]) == 0
}

deny contains msg if {
	some [addr, a] in addressed("aws_cloudwatch_metric_alarm")
	not a.alarm_actions
	msg := sprintf("[observability] Alarm '%v' has no alarm_actions (nobody gets told).", [addr])
}

warn contains "[observability] No CloudWatch dashboard defined." if {
	count(resources("aws_cloudwatch_dashboard")) == 0
}
