package academy

import data.lib.resources
import rego.v1

deny contains "[academy] Do not create IAM users or access keys (blocked in AWS Academy, and a credential-leak risk)." if {
	count(resources("aws_iam_user")) + count(resources("aws_iam_access_key")) > 0
}

deny contains "[academy] This lab needs no IAM roles; role creation is blocked in AWS Academy." if {
	count(resources("aws_iam_role")) > 0
}
