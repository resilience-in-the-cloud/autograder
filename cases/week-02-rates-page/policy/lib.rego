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
graded_once := {"aws_cloudwatch_metric_alarm", "aws_cloudfront_distribution"}

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

# Same, keyed by resource name (for "every bucket needs X" rules).
named_resources(type) := {name: r |
	some f in input
	some name, r in f.contents.resource[type]
}

# HCL blocks parse to an object when written once and to an array when repeated.
as_list(x) := x if is_array(x)

as_list(x) := [x] if not is_array(x)

# Does a resource's `bucket` argument point at aws_s3_bucket.<name>?
refers_to_bucket(r, name) if contains(r.bucket, sprintf("aws_s3_bucket.%s.", [name]))

refers_to_bucket(r, name) if contains(r.bucket, sprintf("aws_s3_bucket.%s[", [name]))

# Top-level blocks (terraform, provider) across files.
blocks(kind) := [b |
	some f in input
	some b in as_list(f.contents[kind])
]
