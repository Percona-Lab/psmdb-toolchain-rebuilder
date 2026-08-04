// upstream toolchain URL in, S3 paths out.
// The agent runs terraform; AWS builds.
// REBUILDER_AWS_CRED can only sts:AssumeRole.

// ── helpers: containers, creds by env not argv ──
def tf(String cmd) {
    sh """
      docker run --rm \\
        -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \\
        -e AWS_DEFAULT_REGION=${env.AWS_REGION} \\
        -e TF_IN_AUTOMATION=1 \\
        -v "\$WORKSPACE/terraform":/tf -w /tf \\
        --entrypoint /bin/sh ${env.TF_IMAGE} -c '${cmd}'
    """
}

def awscli(String cmd) {
    sh """
      docker run --rm \\
        -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \\
        -e AWS_DEFAULT_REGION=${env.AWS_REGION} \\
        -v "\$WORKSPACE":/w -w /w \\
        --entrypoint /bin/sh ${env.AWSCLI_IMAGE} -c '${cmd}'
    """
}

pipeline {
    agent { label params.AGENT_LABEL ?: 'launcher-x64' }

    parameters {
        string(name: 'UPSTREAM_TOOLCHAIN_URL', defaultValue: '',
               description: 'Full URL of the upstream x86_64 toolchain to mirror. Prefer the FULL archive (it carries logs/ with component versions), e.g. s3://boxes.10gen.com/build/toolchain/mongodbtoolchain-debian13-<ID>.tar.gz')
        string(name: 'AGENT_LABEL', defaultValue: 'launcher-x64',
               description: 'Jenkins node label. Only needs docker — it just runs terraform and polls S3 while AWS does the build.')
        string(name: 'TF_ROLE_ARN', defaultValue: '',
               description: 'ARN of the psmdb-toolchain-rebuilder-tf role that Terraform assumes. Kept out of the repo because it carries the account id.')
        booleanParam(name: 'KEEP_COMPUTE', defaultValue: false, description: 'Skip teardown (debug: leave the ASG/volume running).')
    }

    options {
        timeout(time: 8, unit: 'HOURS')     // one spot lifetime should cover it; ASG self-heals
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '30'))
        ansiColor('xterm')
    }

    environment {
        AWS_REGION   = 'us-west-2'
        BUCKET       = 'psmdb-arm64-toolchains'
        TF_IMAGE     = 'hashicorp/terraform:1.13'
        AWSCLI_IMAGE = 'amazon/aws-cli:2'
    }

    stages {
        stage('Resolve') {
            steps {
                script {
                    if (!params.UPSTREAM_TOOLCHAIN_URL?.trim()) { error 'UPSTREAM_TOOLCHAIN_URL is required' }
                    if (!params.TF_ROLE_ARN?.trim()) { error 'TF_ROLE_ARN is required' }
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
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'REBUILDER_AWS_CRED']]) {
                    sh 'tar -C scripts -czf scripts.tar.gz .'
                    script {
                        awscli("aws s3 cp scripts.tar.gz s3://${env.BUCKET}/${env.SCRIPTS_KEY}")
                    }
                }
            }
        }

        stage('Terraform apply') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'REBUILDER_AWS_CRED']]) {
                    script {
                        writeFile file: 'terraform/backend.hcl',
                                  text: "assume_role = { role_arn = \"${params.TF_ROLE_ARN}\" }\n"
                        tf("terraform init -input=false -backend-config=backend.hcl" +
                           " && terraform apply -input=false -auto-approve" +
                           " -var=toolchain_id=${env.TOOLCHAIN_ID}" +
                           " -var=upstream_url=${params.UPSTREAM_TOOLCHAIN_URL}" +
                           " -var=scripts_key=${env.SCRIPTS_KEY}" +
                           " -var=bucket_name=${env.BUCKET}" +
                           " -var=assume_role_arn=${params.TF_ROLE_ARN}" +
                           " -var=region=${env.AWS_REGION}")
                    }
                }
            }
        }

        stage('Wait for build (DONE marker)') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'REBUILDER_AWS_CRED']]) {
                    script {
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
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'REBUILDER_AWS_CRED']]) {
                    script {
                        awscli("aws s3 ls s3://${env.BUCKET}/output/${env.TOOLCHAIN_ID}/; " +
                               "echo 'build logs (one per instance that worked the job):'; " +
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
                    withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'REBUILDER_AWS_CRED']]) {
                        tf("terraform destroy -input=false -auto-approve" +
                           " -target=aws_autoscaling_group.rebuilder -target=aws_ebs_volume.build" +
                           " -var=toolchain_id=${env.TOOLCHAIN_ID ?: 'none'}" +
                           " -var=upstream_url=none -var=scripts_key=none" +
                           " -var=bucket_name=${env.BUCKET} -var=assume_role_arn=${params.TF_ROLE_ARN}" +
                           " -var=region=${env.AWS_REGION} || true")
                    }
                }
            }
        }
    }
}
