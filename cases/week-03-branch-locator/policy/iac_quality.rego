package iac_quality

import data.lib.variables
import rego.v1

# Every input is typed and documented - the variables ARE the runbook knobs.
deny contains msg if {
	some name, v in variables
	not v.description
	msg := sprintf("[iac-quality] Variable '%v' has no description.", [name])
}

deny contains msg if {
	some name, v in variables
	not v.type
	msg := sprintf("[iac-quality] Variable '%v' has no type.", [name])
}

# Existence rules only count resources created exactly once (lib.created), so
# count / for_each on these types would hide them from the checks.
deny contains msg if {
	some addr in data.lib.multi
	msg := sprintf("[iac-quality] %s uses count or for_each. Declare it once, without count/for_each, so the checks can see it.", [addr])
}
