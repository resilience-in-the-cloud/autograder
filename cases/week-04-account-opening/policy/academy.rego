package academy

import data.lib.resources
import rego.v1

deny contains "[academy] Do not create IAM users or access keys (blocked in AWS Academy, and a credential-leak risk)." if {
	count(resources("aws_iam_user")) + count(resources("aws_iam_access_key")) > 0
}

deny contains "[academy] Do not create instance profiles in Academy; use the LabInstanceProfile data source (guard any portable path with count = var.use_lab_role ? 0 : 1)." if {
	some p in resources("aws_iam_instance_profile")
	not p.count
}
