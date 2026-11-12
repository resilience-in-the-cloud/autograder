package iac_quality

import data.lib.resources
import rego.v1

variables := [{"name": name, "v": v} |
	some f in input
	some name, v in f.contents.variable
]

deny contains msg if {
	some lt in resources("aws_launch_template")
	is_string(lt.image_id)
	startswith(lt.image_id, "ami-")
	msg := sprintf("[iac-quality] Launch template uses a hard-coded AMI (%v); look it up from the SSM public parameter so it stays patched and region-portable.", [lt.image_id])
}

deny contains msg if {
	some x in variables
	not x.v.description
	msg := sprintf("[iac-quality] Variable '%v' has no description.", [x.name])
}

deny contains msg if {
	some x in variables
	not x.v.type
	msg := sprintf("[iac-quality] Variable '%v' has no type.", [x.name])
}

# Existence rules only count resources created exactly once (lib.created), so
# count / for_each on these types would hide them from the checks.
deny contains msg if {
	some addr in data.lib.multi
	msg := sprintf("[iac-quality] %s uses count or for_each. Declare it once, without count/for_each, so the checks can see it.", [addr])
}
