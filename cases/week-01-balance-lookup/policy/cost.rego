package cost

import data.lib.resources
import rego.v1

deny contains "[cost] Log group has no retention_in_days (logs kept forever)." if {
	some lg in resources("aws_cloudwatch_log_group")
	not lg.retention_in_days
}
