package security

import data.lib.addressed
import data.lib.blocks
import data.lib.resources
import rego.v1

# Explicit encryption at rest (KMS-managed key) is audit evidence for the CRO.
deny contains msg if {
	some [addr, t] in addressed("aws_dynamodb_table")
	not sse_enabled(t)
	msg := sprintf("[security] DynamoDB table '%v' does not declare server_side_encryption { enabled = true } (KMS-managed key = audit evidence).", [addr])
}

sse_enabled(t) if {
	some b in blocks(object.get(t, "server_side_encryption", []))
	b.enabled == true
}

# Lambda permissions for API Gateway must be scoped to this API.
deny contains "[security] aws_lambda_permission for apigateway.amazonaws.com has no source_arn (any API in any account could invoke it)." if {
	some p in resources("aws_lambda_permission")
	p.principal == "apigateway.amazonaws.com"
	not p.source_arn
}
