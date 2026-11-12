package cost

import data.lib.as_list
import data.lib.resources
import rego.v1

deny contains "[cost] No aws_s3_bucket_lifecycle_configuration: noncurrent object versions are kept (and billed) forever." if {
	count(resources("aws_s3_bucket")) > 0
	count(resources("aws_s3_bucket_lifecycle_configuration")) == 0
}

deny contains "[cost] price_class = \"PriceClass_All\" pays for edges NNB's US customers don't need; use PriceClass_100." if {
	some d in resources("aws_cloudfront_distribution")
	d.price_class == "PriceClass_All"
}

warn contains "[cost] price_class is not set to PriceClass_100." if {
	some d in resources("aws_cloudfront_distribution")
	not d.price_class == "PriceClass_100"
}
