# Week 4 resilience checks: multi-AZ, health checks, self-healing, elasticity.
#   conftest test --parser hcl2 --combine --all-namespaces --policy policy terraform/*.tf
package resilience

import data.lib.addressed
import data.lib.blocks
import data.lib.created
import data.lib.refers_to
import data.lib.resources
import rego.v1

deny contains "[resilience] No aws_autoscaling_group: the web tier cannot self-heal." if {
	count(created("aws_autoscaling_group")) == 0
}

deny contains msg if {
	some [addr, g] in addressed("aws_autoscaling_group")
	is_number(g.min_size)
	g.min_size < 2
	msg := sprintf("[resilience] Auto Scaling group '%v' has min_size %v; use >= 2 so losing one instance (or AZ) is not an outage.", [addr, g.min_size])
}

warn contains msg if {
	some [addr, g] in addressed("aws_autoscaling_group")
	not is_number(g.min_size)
	msg := sprintf("[resilience] Auto Scaling group '%v' min_size is not a literal; the Terraform tests verify it is >= 2.", [addr])
}

deny contains msg if {
	some [addr, g] in addressed("aws_autoscaling_group")
	object.get(g, "health_check_type", "EC2") != "ELB"
	msg := sprintf("[resilience] Auto Scaling group '%v' uses EC2 health checks; set health_check_type = \"ELB\" so instances failing /health are replaced.", [addr])
}

deny contains msg if {
	some [addr, g] in addressed("aws_autoscaling_group")
	not g.health_check_grace_period
	msg := sprintf("[resilience] Auto Scaling group '%v' has no health_check_grace_period.", [addr])
}

deny contains msg if {
	some [addr, g] in addressed("aws_autoscaling_group")
	not g.vpc_zone_identifier
	msg := sprintf("[resilience] Auto Scaling group '%v' has no vpc_zone_identifier (subnets in >= 2 AZs).", [addr])
}

deny contains msg if {
	some [addr, g] in addressed("aws_autoscaling_group")
	is_array(g.vpc_zone_identifier)
	count(g.vpc_zone_identifier) < 2
	not refers_to(g.vpc_zone_identifier, "aws_subnets")
	msg := sprintf("[resilience] Auto Scaling group '%v' lists fewer than 2 subnets: a single AZ is a single point of failure.", [addr])
}

deny contains msg if {
	some [addr, g] in addressed("aws_autoscaling_group")
	refers_to(g.vpc_zone_identifier, "aws_subnets.default.ids[")
	msg := sprintf("[resilience] Auto Scaling group '%v' picks a single subnet out of the list; use all of data.aws_subnets.default.ids.", [addr])
}

deny contains "[resilience] No scaling policy (aws_autoscaling_policy): the group cannot grow under load." if {
	count(resources("aws_autoscaling_group")) > 0
	count(created("aws_autoscaling_policy")) == 0
}

deny contains msg if {
	some [addr, tg] in addressed("aws_lb_target_group")
	count(blocks(object.get(tg, "health_check", []))) == 0
	msg := sprintf("[resilience] Target group '%v' has no health_check block.", [addr])
}

deny contains msg if {
	some [addr, tg] in addressed("aws_lb_target_group")
	some hc in blocks(object.get(tg, "health_check", []))
	object.get(hc, "path", "/") == "/"
	msg := sprintf("[resilience] Target group '%v' health check probes '/'; probe a real health endpoint like /health.", [addr])
}

warn contains msg if {
	some [addr, lb] in addressed("aws_lb")
	object.get(lb, "enable_deletion_protection", false) == false
	msg := sprintf("[resilience] Load balancer '%v' has deletion protection off. Fine for a lab you tear down nightly; in production turn it on so a stray 'terraform destroy' cannot take the bank offline.", [addr])
}
