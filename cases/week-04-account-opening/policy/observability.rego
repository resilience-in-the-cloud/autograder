package observability

import data.lib.addressed
import data.lib.created
import data.lib.resources
import rego.v1

alarms := created("aws_cloudwatch_metric_alarm")

deny contains "[observability] No CloudWatch alarm on the target group's 'UnHealthyHostCount' metric." if {
	count([a | some a in alarms; a.metric_name == "UnHealthyHostCount"]) == 0
}

deny contains "[observability] No CloudWatch alarm on 'HTTPCode_Target_5XX_Count'." if {
	count([a | some a in alarms; a.metric_name == "HTTPCode_Target_5XX_Count"]) == 0
}

deny contains msg if {
	some [addr, a] in addressed("aws_cloudwatch_metric_alarm")
	not a.alarm_actions
	msg := sprintf("[observability] Alarm '%v' has no alarm_actions (nobody gets told).", [addr])
}

warn contains "[observability] No CloudWatch dashboard defined." if {
	count(resources("aws_cloudwatch_dashboard")) == 0
}
