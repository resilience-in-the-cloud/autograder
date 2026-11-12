package academy

import data.lib.resources
import rego.v1

deny contains "[academy] Do not create IAM users or access keys (blocked in AWS Academy, and a credential-leak risk)." if {
	count(resources("aws_iam_user")) + count(resources("aws_iam_access_key")) > 0
}

deny contains "[academy] aws_iam_role must be conditional (count = var.use_lab_role ? 0 : 1); Academy blocks iam:CreateRole." if {
	some r in resources("aws_iam_role")
	not r.count
}
