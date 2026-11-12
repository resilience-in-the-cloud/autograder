package security

import data.lib.as_list
import data.lib.named_resources
import data.lib.refers_to_bucket
import data.lib.resources
import rego.v1

deny contains msg if {
	some name, _ in named_resources("aws_s3_bucket")
	not bpa_ok(name)
	msg := sprintf("[security] Bucket '%v' needs an aws_s3_bucket_public_access_block with all four settings = true.", [name])
}

bpa_ok(name) if {
	some b in resources("aws_s3_bucket_public_access_block")
	refers_to_bucket(b, name)
	b.block_public_acls == true
	b.block_public_policy == true
	b.ignore_public_acls == true
	b.restrict_public_buckets == true
}

deny contains msg if {
	some name, _ in named_resources("aws_s3_bucket")
	not sse_ok(name)
	msg := sprintf("[security] Bucket '%v' needs an aws_s3_bucket_server_side_encryption_configuration.", [name])
}

sse_ok(name) if {
	some c in resources("aws_s3_bucket_server_side_encryption_configuration")
	refers_to_bucket(c, name)
}

deny contains "[security] Do not use S3 static website hosting; serve the private bucket through CloudFront + OAC." if {
	count(resources("aws_s3_bucket_website_configuration")) > 0
}

deny contains "[security] Every S3 origin must set origin_access_control_id (OAC) so the buckets stay private." if {
	some d in resources("aws_cloudfront_distribution")
	some o in as_list(d.origin)
	not o.origin_access_control_id
}

deny contains "[security] viewer_protocol_policy = \"allow-all\" serves the bank's page over plain HTTP." if {
	some d in resources("aws_cloudfront_distribution")
	some b in as_list(d.default_cache_behavior)
	b.viewer_protocol_policy == "allow-all"
}

warn contains "[security] aws_cloudfront_origin_access_identity (OAI) is legacy; use aws_cloudfront_origin_access_control." if {
	count(resources("aws_cloudfront_origin_access_identity")) > 0
}
