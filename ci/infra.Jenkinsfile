pipeline {
    agent any

    options {
        disableConcurrentBuilds()
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '10'))
    }

    parameters {
        choice(name: 'TF_DIR', choices: ['infra-cicd', 'infra-ecs'], description: 'Which Terraform folder')
        choice(name: 'ACTION', choices: ['plan', 'apply', 'destroy'],
               description: 'plan = only show changes. apply/destroy = ask for approval, then run')
        string(name: 'MY_IP', defaultValue: '', description: 'Only for infra-ecs: your public IP with /32')
    }

    environment {
        TF_IN_AUTOMATION    = 'true'
        TF_INPUT            = '0'
        TF_VAR_my_ip        = "${params.MY_IP}"
        AWS_DEFAULT_REGION  = 'us-east-1'
        TF_PLUGIN_CACHE_DIR = '/tmp/tfcache'
    }

    stages {
        stage('Plan') {
            agent {
                docker {
                    image 'hashicorp/terraform:1.13'
                    args  '--entrypoint= -e HOME=/tmp -v /var/lib/jenkins/tf-plugin-cache:/tmp/tfcache'
                    reuseNode true
                }
            }
            steps {
                withCredentials([
                    string(credentialsId: 'aws-access-key-id',     variable: 'AWS_ACCESS_KEY_ID'),
                    string(credentialsId: 'aws-secret-access-key', variable: 'AWS_SECRET_ACCESS_KEY')
                ]) {
                    dir(params.TF_DIR) {
                        sh '''
                            if [ "$TF_DIR" = "infra-ecs" ]; then
                                test -n "$TF_VAR_my_ip" || { echo "MY_IP is empty for infra-ecs."; exit 1; }
                            fi
                            terraform version
                            terraform fmt -check -diff || echo "WARNING: some files are not formatted"
                            terraform init
                            terraform validate
                            if [ "$ACTION" = "destroy" ]; then
                                terraform plan -destroy -out=tfplan
                            else
                                terraform plan -out=tfplan
                            fi
                        '''
                    }
                }
            }
        }

        stage('Approve') {
            when { expression { params.ACTION in ['apply', 'destroy'] } }
            steps {
                timeout(time: 30, unit: 'MINUTES') {
                    input message: "Read the plan in the log above. Run '${params.ACTION}' on ${params.TF_DIR}?",
                          ok: params.ACTION.toUpperCase()
                }
            }
        }

        stage('Apply') {
            when { expression { params.ACTION in ['apply', 'destroy'] } }
            agent {
                docker {
                    image 'hashicorp/terraform:1.13'
                    args  '--entrypoint= -e HOME=/tmp -v /var/lib/jenkins/tf-plugin-cache:/tmp/tfcache'
                    reuseNode true
                }
            }
            steps {
                withCredentials([
                    string(credentialsId: 'aws-access-key-id',     variable: 'AWS_ACCESS_KEY_ID'),
                    string(credentialsId: 'aws-secret-access-key', variable: 'AWS_SECRET_ACCESS_KEY')
                ]) {
                    dir(params.TF_DIR) {
                        sh 'terraform apply tfplan'
                        sh 'terraform output || true'
                    }
                }
            }
        }
    }

    post {
        always  { sh 'rm -f "$TF_DIR/tfplan"' }
        aborted { echo 'Not approved or aborted. Nothing was changed.' }
        failure { echo 'Failed. If it failed in Apply, run a new plan to see the state.' }
    }
}
