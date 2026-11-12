# Week 2 resilience checks: static redundancy, caching, origin failover.
# Package name = rubric category. Run all packages with:
#   conftest test --parser hcl2 --combine --all-namespaces --policy policy terraform/*.tf
package resilience

import data.lib.as_list
import data.lib.created
import data.lib.named_resources
import data.lib.refers_to_bucket
import data.lib.resources
import rego.v1

distributions := resources("aws_cloudfront_distribution")

# Versioning enabled on every bucket
deny contains msg if {
	some name, _ in named_resources("aws_s3_bucket")
	not versioning_ok(name)
	msg := sprintf("[resilience] Bucket '%v' needs versioning with status = \"Enabled\" (your undo button for a bad or deleted file).", [name])
}

versioning_ok(name) if {
	some v in resources("aws_s3_bucket_versioning")
	refers_to_bucket(v, name)
	some c in as_list(v.versioning_configuration)
	c.status == "Enabled"
}

deny contains "[resilience] No aws_cloudfront_distribution: the rates page needs a CDN in front of S3." if {
	count(created("aws_cloudfront_distribution")) == 0
}

deny contains "[resilience] The distribution needs two S3 origins (primary + replica) for origin failover." if {
	some d in distributions
	count(as_list(d.origin)) < 2
}

deny contains "[resilience] The distribution has no origin_group: if the primary bucket fails, visitors see errors." if {
	some d in distributions
	not d.origin_group
}

deny contains msg if {
	some d in distributions
	some g in as_list(d.origin_group)
	codes := {c | some fc in as_list(g.failover_criteria); some c in fc.status_codes}
	missing := {500, 502, 503, 504} - codes
	count(missing) > 0
	msg := sprintf("[resilience] Origin group failover_criteria is missing status codes %v.", [missing])
}

deny contains "[resilience] default_cache_behavior must target the origin group (not a single bucket origin)." if {
	some d in distributions
	d.origin_group
	targets := {g.origin_id | some g in as_list(d.origin_group)}
	some b in as_list(d.default_cache_behavior)
	not b.target_origin_id in targets
}

deny contains "[resilience] Set default_root_object = \"index.html\"." if {
	some d in distributions
	not d.default_root_object
}

deny contains "[resilience] No custom_error_response for 403/5xx: visitors see raw S3/CloudFront errors when every origin fails." if {
	some d in distributions
	not maintenance_page(d)
}

maintenance_page(d) if {
	some e in as_list(d.custom_error_response)
	e.error_code >= 500
}

maintenance_page(d) if {
	some e in as_list(d.custom_error_response)
	e.error_code == 403
}

# Lab-only shortcut: flag it so the trade-off is discussed (warning, not scored).
warn contains msg if {
	some name, b in named_resources("aws_s3_bucket")
	b.force_destroy == true
	msg := sprintf("[resilience] Bucket '%v' has force_destroy = true. Fine for a 4-hour lab; in production it lets one 'terraform destroy' wipe the site and every old version.", [name])
}

warn contains "[resilience] Replica is not configured for cross-region replication (aws_s3_bucket_replication_configuration). OK in Academy; production needs the replica in a second region." if {
	some d in distributions
	count(as_list(d.origin)) >= 2
	count(resources("aws_s3_bucket_replication_configuration")) == 0
}
