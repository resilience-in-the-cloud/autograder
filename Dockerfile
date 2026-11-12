# Grader image for grade-all.sh's per-repo container mode (GRADER_IMAGE).
# Same tool versions as .github/workflows/grade.yml. No credentials are baked in or passed.
#   docker build -t itcs5010-grader autograder/
#   GRADER_IMAGE=itcs5010-grader autograder/grade-all.sh week-03-branch-locator
FROM python:3.12-slim
ARG TERRAFORM=1.14.9
ARG TFLINT=0.55.0
ARG CONFTEST=0.56.0
RUN apt-get update && apt-get install -y --no-install-recommends curl unzip git ca-certificates \
 && curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM}/terraform_${TERRAFORM}_linux_amd64.zip" -o /tmp/tf.zip \
 && unzip -oq /tmp/tf.zip -d /usr/local/bin \
 && curl -fsSL "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT}/tflint_linux_amd64.zip" -o /tmp/tflint.zip \
 && unzip -oq /tmp/tflint.zip -d /usr/local/bin \
 && curl -fsSL "https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST}/conftest_${CONFTEST}_Linux_x86_64.tar.gz" \
    | tar xz -C /usr/local/bin conftest \
 && rm -rf /tmp/*.zip /var/lib/apt/lists/* \
 && pip install --no-cache-dir "checkov==3.4.3" "pytest==8.3.4"
ENV PYTHON=python3 TF_IN_AUTOMATION=1
WORKDIR /work
