package lib

import rego.v1

# Resources of a type that are always created exactly once. Use this for "an X
# must exist" rules: a block with `count = 0` (or a for_each that may be empty)
# would otherwise satisfy the rule without creating anything.
created(type) := [r |
	some f in input
	some name, r in f.contents.resource[type]
	single(r)
]

single(r) if {
	not "count" in object.keys(r)
	not "for_each" in object.keys(r)
}

single(r) if {
	r.count == 1
	not "for_each" in object.keys(r)
}

# Types that existence rules look up with created(). iac_quality denies
# count/for_each on them, so a team learns why its resource "doesn't exist".
graded_once := {"aws_cloudwatch_metric_alarm"}

# Addresses of graded_once resources whose instance count isn't a literal 1.
multi := [sprintf("%s.%s", [type, name]) |
	some f in input
	some type in graded_once
	some name, r in f.contents.resource[type]
	not single(r)
]

# All resources of a given type across every .tf file (conftest --combine).
resources(type) := [r |
	some f in input
	some name, r in f.contents.resource[type]
]

# [address, block] pairs (e.g. "aws_dynamodb_table.branches"), so messages can
# name a resource by its Terraform address instead of a raw "${...}" expression.
addressed(type) := [[sprintf("%s.%s", [type, name]), r] |
	some f in input
	some name, r in f.contents.resource[type]
]

# All variable blocks, as {name: block}.
variables[name] := v if {
	some f in input
	some name, v in f.contents.variable
}

# The hcl2 parser gives a single nested block as an object and repeated
# blocks as an array; normalise to an array.
blocks(x) := x if is_array(x)

blocks(x) := [x] if is_object(x)
