package resilience

import data.lib.resources
import rego.v1

deny contains "[resilience] Lambda function has no explicit timeout." if {
	some fn in resources("aws_lambda_function")
	not fn.timeout
}
