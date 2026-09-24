// SIT223 7.3HD — DevOps pipeline for the Taskmaster CV worker.
//
// Stage logic lives in scripts/*.sh rather than inline Groovy, so each stage can
// be run and debugged from a terminal without a Jenkins build.

pipeline {
    agent any

    options {
        timestamps()
        // Keep the last 15 builds; each archives a ~39MB artefact.
        buildDiscarder(logRotator(numToKeepStr: '15'))
        timeout(time: 30, unit: 'MINUTES')
        // Two runs analysing the same SonarCloud project at once race each
        // other; builds 8 and 9 collided that way.
        disableConcurrentBuilds()
    }

    triggers {
        // Jenkins listens on 127.0.0.1, so GitHub webhooks cannot reach it.
        // Poll instead: every 5 minutes, build only if the SHA changed.
        pollSCM('H/5 * * * *')
    }

    environment {
        // Homebrew binaries (python@3.11, curl, git) are not on Jenkins' default PATH.
        PATH = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }

    stages {

        stage('Build') {
            steps {
                sh './scripts/build.sh'
            }
            post {
                success {
                    // fingerprint lets Jenkins trace this exact artefact through
                    // the Deploy and Release stages later.
                    archiveArtifacts artifacts: 'dist/*.tar.gz, VERSION, requirements.lock',
                                     fingerprint: true
                }
            }
        }

        stage('Test') {
            steps {
                sh './scripts/test.sh'
            }
            post {
                always {
                    // Publish results even when tests fail, so the console is
                    // not the only place the failure is visible.
                    junit testResults: 'reports/junit.xml', allowEmptyResults: false
                    archiveArtifacts artifacts: 'reports/coverage.xml', allowEmptyArchive: true
                }
            }
        }

        stage('Code Quality') {
            steps {
                // SONAR_TOKEN is an existing Jenkins credential, reused from
                // the 7.1C/8.2C pipeline. Tokens are account-scoped, so it
                // covers this project too.
                withCredentials([string(credentialsId: 'SONAR_TOKEN', variable: 'SONAR_TOKEN')]) {
                    sh './scripts/quality.sh'
                }
            }
        }

        stage('Security') {
            steps {
                sh './scripts/security.sh'
            }
            post {
                always {
                    archiveArtifacts artifacts: 'reports/bandit.json, reports/pip-audit-*.json',
                                     allowEmptyArchive: true
                }
            }
        }

        stage('Deploy') {
            steps {
                sh './scripts/deploy.sh staging'
            }
        }

        stage('Release') {
            steps {
                sh './scripts/release.sh'
            }
        }

        stage('Monitoring') {
            steps {
                sh './scripts/monitoring.sh'
            }
        }

    }

    post {
        success { echo "Pipeline OK — build ${env.BUILD_NUMBER}" }
        failure { echo "Pipeline FAILED at stage: ${env.STAGE_NAME}" }
        always  { echo "Finished: ${currentBuild.currentResult}" }
    }
}
