// Order Desk: CI (test, build, push to ECR) and CD (deploy to ECS)
pipeline {
    // The whole pipeline runs on the EC2 build agent, not on the Jenkins server.
    agent { label 'build-agent' }

    triggers { pollSCM('H/2 * * * *') }

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '15'))
    }

    parameters {
        string(name: 'ROLLBACK_TAG', defaultValue: '',
               description: 'Optional. Deploy an image tag that is already in ECR (skips tests and build). Example: 12-a1b2c3d')
        booleanParam(name: 'REQUIRE_APPROVAL', defaultValue: true,
                     description: 'Wait for a click before deploying')
    }

    environment {
        AWS_DEFAULT_REGION = 'us-east-1'
        ECS_CLUSTER        = 'orderdesk-ecs-cluster'
        DESIRED_COUNT      = '2'
    }

    stages {

        stage('Prepare') {
            steps {
                script {
                    env.GIT_SHORT    = sh(returnStdout: true, script: 'git rev-parse --short HEAD').trim()
                    env.IMAGE_TAG    = params.ROLLBACK_TAG ? params.ROLLBACK_TAG : "${env.BUILD_NUMBER}-${env.GIT_SHORT}"
                    env.ECR_REGISTRY = sh(returnStdout: true,
                        script: 'echo "$(aws sts get-caller-identity --query Account --output text).dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"').trim()
                    env.BACKEND_IMAGE  = "${env.ECR_REGISTRY}/orderdesk-backend:${env.IMAGE_TAG}"
                    env.FRONTEND_IMAGE = "${env.ECR_REGISTRY}/orderdesk-frontend:${env.IMAGE_TAG}"
                }
                echo "Image tag: ${env.IMAGE_TAG}"
                sh 'git log -1 --pretty="%h %an: %s"'
            }
        }

        // ---------------------------- CI ----------------------------
        stage('Test and build') {
            when { expression { !params.ROLLBACK_TAG } }
            parallel {

                stage('Backend tests (Maven container)') {
                    agent {
                        docker {
                            image 'maven:3.9-eclipse-temurin-21'
                            args  '-e HOME=/tmp -e MAVEN_OPTS=-Duser.home=/tmp -v /home/jenkins/.m2:/tmp/.m2'
                            reuseNode true
                        }
                    }
                    steps {
                        dir('backend') {
                            sh 'mvn -B -Dmaven.repo.local=/tmp/.m2/repository test'
                        }
                    }
                    post {
                        always { junit allowEmptyResults: true, testResults: 'backend/target/surefire-reports/*.xml' }
                    }
                }

                stage('Frontend build (Node container)') {
                    agent {
                        docker {
                            image 'node:24-alpine'
                            args  '-e HOME=/tmp'
                            reuseNode true
                        }
                    }
                    steps {
                        dir('frontend') {
                            sh 'npm ci'
                            sh 'npm run build'
                        }
                    }
                }
            }
        }

        // These two use the agent's own Docker (a container cannot build images without one)
        stage('Build images') {
            when { expression { !params.ROLLBACK_TAG } }
            steps {
                sh '''
                    docker build -t "$BACKEND_IMAGE" backend
                    docker build --build-arg VITE_API_URL= -t "$FRONTEND_IMAGE" frontend
                '''
            }
        }

        stage('Push to ECR') {
            when { expression { !params.ROLLBACK_TAG } }
            steps {
                sh '''
                    aws ecr get-login-password | docker login --username AWS --password-stdin "$ECR_REGISTRY"
                    docker push "$BACKEND_IMAGE"
                    docker push "$FRONTEND_IMAGE"
                '''
            }
        }

        // ---------------------------- CD ----------------------------
        stage('Approve deploy') {
            when {
                allOf {
                    expression { env.GIT_BRANCH in ['origin/main', 'main'] }
                    expression { params.REQUIRE_APPROVAL != false }
                }
            }
            steps {
                timeout(time: 30, unit: 'MINUTES') {
                    input message: "Deploy ${env.IMAGE_TAG} to ECS?", ok: 'Deploy'
                }
            }
        }

        stage('Deploy to ECS') {
            when { expression { env.GIT_BRANCH in ['origin/main', 'main'] } }
            // custom container agent: built from ci/Dockerfile.deploy (AWS CLI + jq)
            agent {
                dockerfile {
                    filename 'Dockerfile.deploy'
                    dir      'ci'
                    args     '--entrypoint= -e HOME=/tmp'
                    reuseNode true
                }
            }
            steps {
                sh 'bash ci/scripts/deploy-ecs-service.sh "$ECS_CLUSTER" backend  backend  "$BACKEND_IMAGE"  "$DESIRED_COUNT"'
                sh 'bash ci/scripts/deploy-ecs-service.sh "$ECS_CLUSTER" frontend frontend "$FRONTEND_IMAGE" "$DESIRED_COUNT"'
            }
        }
    }

    post {
        always {
            // free the agent's disk: remove this build's images and dangling layers
            sh 'docker rmi "$BACKEND_IMAGE" "$FRONTEND_IMAGE" || true; docker image prune -f'
        }
        success { echo "Done: ${env.IMAGE_TAG}" }
        failure { echo 'Failed. Open the red stage in the console log.' }
    }
}
