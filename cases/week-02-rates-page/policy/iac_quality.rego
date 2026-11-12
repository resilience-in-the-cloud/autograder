package iac_quality

import data.lib.as_list
import data.lib.blocks
import rego.v1

deny contains "[iac-quality] terraform block must pin required_version." if {
	count([t | some t in blocks("terraform"); t.required_version]) == 0
}

deny contains "[iac-quality] Every aws provider block needs default_tags (Course, Case, Team) so resources can be found and cleaned up." if {
	some p in blocks("provider")
	some a in as_list(p.aws)
	not a.default_tags
}

# Existence rules only count resources created exactly once (lib.created), so
# count / for_each on these types would hide them from the checks.
deny contains msg if {
	some addr in data.lib.multi
	msg := sprintf("[iac-quality] %s uses count or for_each. Declare it once, without count/for_each, so the checks can see it.", [addr])
}
