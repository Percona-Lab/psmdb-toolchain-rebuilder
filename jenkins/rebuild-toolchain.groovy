// upstream toolchain URL in, S3 paths out.
// The agent runs terraform; AWS builds.
// REBUILDER_AWS_CRED can only sts:AssumeRole.
// REBUILDER_TF_ROLE_ARN: secret text, role ARN.

// ── helpers: containers, creds by env not argv ──
// ARN stays out of params and argv
def withAws(Closure body) {
    withCredentials([
        [$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'REBUILDER_AWS_CRED'],
        string(credentialsId: 'REBUILDER_TF_ROLE_ARN', variable: 'TF_ROLE_ARN'),
    ]) { body() }
}

def tf(String cmd) {
    sh """
      docker run --rm \\
        -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \\
        -e AWS_DEFAULT_REGION=${env.AWS_REGION} \\
        -e TF_IN_AUTOMATION=1 \\
        -e TF_VAR_assume_role_arn="\$TF_ROLE_ARN" \\
        -v "\$WORKSPACE/terraform":/tf -w /tf \\
        --entrypoint /bin/sh ${env.TF_IMAGE} -c '${cmd}'
    """
}

// the key may only assume the role.
// Profile makes the CLI re-assume per call,
// so hours of polling outlive the session.
def awscli(String cmd) {
    writeFile file: '.aws-assume.sh', text: '''\
mkdir -p ~/.aws
printf '[base]\\naws_access_key_id = %s\\naws_secret_access_key = %s\\n' \\
    "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" > ~/.aws/credentials
printf '[profile tf]\\nrole_arn = %s\\nsource_profile = base\\n' \\
    "$TF_ROLE_ARN" > ~/.aws/config
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export AWS_PROFILE=tf
'''
    sh """
      docker run --rm \\
        -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \\
        -e AWS_DEFAULT_REGION=${env.AWS_REGION} \\
        -e TF_ROLE_ARN \\
        -v "\$WORKSPACE":/w -w /w \\
        --entrypoint /bin/sh ${env.AWSCLI_IMAGE} -c '. /w/.aws-assume.sh && ${cmd}'
    """
}

pipeline {
    agent { label params.AGENT_LABEL ?: 'launcher-x64' }

    parameters {
        string(name: 'UPSTREAM_TOOLCHAIN_URL', defaultValue: '',
               description: 'Full URL of the upstream x86_64 toolchain to mirror. Prefer the FULL archive (it carries logs/ with component versions), e.g. s3://boxes.10gen.com/build/toolchain/mongodbtoolchain-debian13-<ID>.tar.gz or https://s3.amazonaws.com/boxes.10gen.com/build/toolchain/mongodbtoolchain-debian13-<ID>.tar.gz')
        string(name: 'AGENT_LABEL', defaultValue: 'launcher-x64',
               description: 'Jenkins node label. Only needs docker — it just runs terraform and polls S3 while AWS does the build.')
        booleanParam(name: 'KEEP_COMPUTE', defaultValue: false, description: 'Skip teardown (debug: leave the ASG/volume running).')
    }

    options {
        timeout(time: 8, unit: 'HOURS')     // one spot lifetime should cover it; ASG self-heals
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '30'))
        timestamps() // no ansiColor plugin on psmdb.cd
    }

    environment {
        AWS_REGION   = 'us-west-2'
        BUCKET       = 'psmdb-arm64-toolchains'
        TF_IMAGE     = 'hashicorp/terraform:1.13'
        AWSCLI_IMAGE = 'amazon/aws-cli:2.37.10' // no floating :2 tag
    }

    stages {
        stage('Resolve') {
            steps {
                script {
                    if (!params.UPSTREAM_TOOLCHAIN_URL?.trim()) { error 'UPSTREAM_TOOLCHAIN_URL is required' }
                    env.UP_BASENAME = params.UPSTREAM_TOOLCHAIN_URL.tokenize('/').last()
                    // names vary; the 40-hex revision does not
                    def m = (env.UP_BASENAME =~ /[0-9a-f]{40}/)
                    if (!m) { error "cannot parse 40-hex toolchain id from ${env.UP_BASENAME}" }
                    env.TOOLCHAIN_ID = m[0]
                    env.SCRIPTS_KEY  = "code/${env.TOOLCHAIN_ID}/scripts.tar.gz"
                    if (!env.UP_BASENAME.contains('debian13')) {
                        echo "WARNING: ${env.UP_BASENAME} is not a debian13 tarball; this job only builds debian13"
                    }
                    currentBuild.displayName = "deb13-arm64 ${env.TOOLCHAIN_ID}"
                    echo "id=${env.TOOLCHAIN_ID}"
                }
            }
        }

        // before the ASG exists: no boot race
        stage('Stage scripts') {
            steps {
                sh 'tar -C scripts -czf scripts.tar.gz .'
                script {
                    withAws {
                        awscli("aws s3 cp scripts.tar.gz s3://${env.BUCKET}/${env.SCRIPTS_KEY}")
                    }
                }
            }
        }

        stage('Terraform apply') {
            steps {
                script {
                    withAws {
                        // shell expands the secret, not Groovy
                        sh 'printf \'assume_role = { role_arn = "%s" }\\n\' "$TF_ROLE_ARN" > terraform/backend.hcl'
                        tf("terraform init -input=false -backend-config=backend.hcl" +
                           " && terraform apply -input=false -auto-approve" +
                           " -var=toolchain_id=${env.TOOLCHAIN_ID}" +
                           " -var=upstream_url=${params.UPSTREAM_TOOLCHAIN_URL}" +
                           " -var=scripts_key=${env.SCRIPTS_KEY}" +
                           " -var=bucket_name=${env.BUCKET}" +
                           " -var=region=${env.AWS_REGION}")
                    }
                }
            }
        }

        stage('Wait for build (DONE marker)') {
            steps {
                script {
                    withAws {
                        // hours, self-healing: only DONE is worth watching
                        def done = "s3://${env.BUCKET}/output/${env.TOOLCHAIN_ID}/DONE"
                        awscli("echo polling ${done}; n=0; until aws s3 ls ${done} >/dev/null 2>&1; do " +
                               "n=\$((n+1)); [ \$((n % 10)) -eq 0 ] && echo \"still building, \${n} min elapsed\"; sleep 60; done; echo DONE seen")
                    }
                }
            }
        }

        stage('Publish paths') {
            steps {
                script {
                    withAws {
                        awscli("aws s3 ls s3://${env.BUCKET}/output/${env.TOOLCHAIN_ID}/; " +
                               "echo \"build logs, one per instance:\"; " +
                               "aws s3 ls s3://${env.BUCKET}/logs/${env.TOOLCHAIN_ID}/ || true")
                        def base = "s3://${env.BUCKET}/output/${env.TOOLCHAIN_ID}"
                        currentBuild.description = [
                            "${base}/bazel_v4_toolchain-debian13-arm64-${env.TOOLCHAIN_ID}.tar.gz",
                            "${base}/bazel_v5_toolchain-debian13-arm64-${env.TOOLCHAIN_ID}.tar.gz",
                            "${base}/bazel_v5_gdb-debian13-arm64-${env.TOOLCHAIN_ID}.tar.gz",
                        ].join('\n')
                    }
                }
            }
        }
    }

    post {
        always {
            script {
                if (params.KEEP_COMPUTE) {
                    echo 'KEEP_COMPUTE=true: leaving ASG + volume up'
                } else {
                    // compute only; LT and policy come back
                    withAws {
                        tf("terraform destroy -input=false -auto-approve" +
                           " -target=aws_autoscaling_group.rebuilder -target=aws_ebs_volume.build" +
                           " -var=toolchain_id=${env.TOOLCHAIN_ID ?: 'none'}" +
                           " -var=upstream_url=none -var=scripts_key=none" +
                           " -var=bucket_name=${env.BUCKET}" +
                           " -var=region=${env.AWS_REGION} || true")
                    }
                }
            }
        }
    }
}
