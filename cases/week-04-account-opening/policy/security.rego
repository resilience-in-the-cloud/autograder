package security

import data.lib.addressed
import data.lib.blocks
import data.lib.data_sources
import data.lib.refers_to
import data.lib.resources
import rego.v1

open_cidr(r) if r.cidr_ipv4 == "0.0.0.0/0"

open_cidr(r) if r.cidr_ipv6 == "::/0"

deny contains msg if {
	some [addr, r] in addressed("aws_vpc_security_group_ingress_rule")
	open_cidr(r)
	not refers_to(r.security_group_id, "aws_security_group.alb.")
	msg := sprintf("[security] Ingress from the whole internet on a non-load-balancer security group (rule %v). Instances should only accept traffic from the ALB.", [addr])
}

deny contains msg if {
	some r in resources("aws_vpc_security_group_ingress_rule")
	open_cidr(r)
	refers_to(r.security_group_id, "aws_security_group.alb.")
	not r.from_port in {80, 443}
	msg := sprintf("[security] The ALB is open to the internet on port %v; only 80/443 are allowed.", [r.from_port])
}

deny contains msg if {
	some [addr, sg] in addressed("aws_security_group")
	some rule in blocks(object.get(sg, "ingress", []))
	some cidr in object.get(rule, "cidr_blocks", [])
	cidr == "0.0.0.0/0"
	not rule.from_port in {80, 443}
	msg := sprintf("[security] Security group '%v' allows 0.0.0.0/0 on port %v.", [addr, rule.from_port])
}

deny contains msg if {
	some [addr, lt] in addressed("aws_launch_template")
	tokens := [t | some m in blocks(object.get(lt, "metadata_options", [])); t := object.get(m, "http_tokens", "optional")]
	not "required" in tokens
	msg := sprintf("[security] Launch template '%v' does not require IMDSv2 (metadata_options.http_tokens = \"required\").", [addr])
}

warn contains "[security] Using the default VPC (public subnets everywhere). Acceptable for week 4; week 5 moves the web tier into private subnets." if {
	some v in data_sources("aws_vpc")
	v["default"] == true
}

warn contains "[security] Listener serves plain HTTP. A real bank needs HTTPS (ACM certificate on port 443); Academy has no domain to issue one for." if {
	some l in resources("aws_lb_listener")
	l.protocol == "HTTP"
}
