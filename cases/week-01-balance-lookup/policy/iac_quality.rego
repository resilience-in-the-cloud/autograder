package iac_quality

import rego.v1

# Existence rules only count resources created exactly once (lib.created), so
# count / for_each on these types would hide them from the checks.
deny contains msg if {
	some addr in data.lib.multi
	msg := sprintf("[iac-quality] %s uses count or for_each. Declare it once, without count/for_each, so the checks can see it.", [addr])
}
