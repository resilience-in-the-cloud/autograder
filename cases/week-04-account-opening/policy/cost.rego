package cost

import data.lib.addressed
import data.lib.resources
import rego.v1

small_types := {"t3.micro", "t3.small", "t2.micro", "t2.small"}

deny contains msg if {
	some lt in resources("aws_launch_template")
	is_string(lt.instance_type)
	not startswith(lt.instance_type, "${")
	not lt.instance_type in small_types
	msg := sprintf("[cost] Instance type '%v' is too big for the Academy budget; use t3.micro.", [lt.instance_type])
}

deny contains msg if {
	some [addr, g] in addressed("aws_autoscaling_group")
	is_number(g.max_size)
	g.max_size > 6
	msg := sprintf("[cost] Auto Scaling group '%v' max_size %v is too high for a lab (<= 6).", [addr, g.max_size])
}

deny contains "[cost] Log group has no retention_in_days (logs kept forever)." if {
	some lg in resources("aws_cloudwatch_log_group")
	not lg.retention_in_days
}
