# Canonical tflint config used by the grader (score.py passes --config).
# A .tflint.hcl in a student repo is ignored, so rules can't be switched off there.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
