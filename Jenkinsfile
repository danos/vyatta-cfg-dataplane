#!groovy

// Copyright (c) 2021, AT&T Intellectual Property.  All rights reserved.

// Pull Request builds might fail due to missing diffs: https://issues.jenkins-ci.org/browse/JENKINS-45997
// Pull Request builds relationship to their targets branch: https://issues.jenkins-ci.org/browse/JENKINS-37491

/* SRC_DIR is where the project will be checked out,
 * and where all the steps will be run.
 */
def SRC_DIR="vyatta-cfg-dataplane"

@NonCPS
def cancelPreviousBuilds() {
    def jobName = env.JOB_NAME
    def buildNumber = env.BUILD_NUMBER.toInteger()
    /* Get job name */
    def currentJob = Jenkins.instance.getItemByFullName(jobName)

    /* Iterating over the builds for specific job */
    for (def build : currentJob.builds) {
        /* If there is a build that is currently running and it's not current build */
        if (build.isBuilding() && build.number.toInteger() != buildNumber) {
            /* Than stop it */
            build.doStop()
        }
    }
}

pipeline {
    agent any

    environment {
        OBS_INSTANCE = 'build-release'
        OBS_TARGET_PROJECT = 'DANOS:Unstable'
        OBS_TARGET_REPO = 'standard'
        OBS_TARGET_ARCH = 'x86_64'
        // Replace : with _ in project name so mountable paths can be used.
        BUILD_ROOT_RELATIVE = 'build-root/' + "${env.OBS_TARGET_PROJECT.replace(':','_')}" + '-' + "${env.OBS_TARGET_REPO}" + '-' + "${OBS_TARGET_ARCH}"
        // Workspace specific chroot location used instead of /var/tmp allows parallel builds between jobs
        OSC_BUILD_ROOT = "${WORKSPACE}" + '/' + "${env.BUILD_ROOT_RELATIVE}"
        // CHANGE_TARGET is set for PRs.
        // When CHANGE_TARGET is not set it's a regular build so we use BRANCH_NAME.
        REF_BRANCH = "${env.CHANGE_TARGET != null ? env.CHANGE_TARGET : env.BRANCH_NAME}"
        // Use env vars if set, else blank.
        OSC_BUILD_ARGS = "${env.OSC_BUILD_ARGS != null ? env.OSC_BUILD_ARGS : ' '}"
        SRC_DIR = "${SRC_DIR}"
    }

    options {
        timeout(time: 60, unit: 'MINUTES')
        checkoutToSubdirectory("${SRC_DIR}")
        quietPeriod(60) // Wait 60 seconds in case there are more SCM pushes/PR merges coming
    }

    stages {

        // A work around, until this feature is implemented: https://issues.jenkins-ci.org/browse/JENKINS-47503
        stage('Cancel older builds') {
            when { allOf {
                // Only if this is a Pull Request
                expression { env.CHANGE_ID != null }
                expression { env.CHANGE_TARGET != null }
            }}
            steps { script {
                cancelPreviousBuilds()
            }}}

        stage(' ') { // No name, looks better in the GUI
            parallel {

                stage('OSC') {
                    stages {
                        stage('OSC Build') {
                            steps {
                                dir("${SRC_DIR}") {
                                    sh "gbp buildpackage --git-verbose --git-ignore-branch -S --no-check-builddeps -us -uc"
                                }
                                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                                    writeFile file: 'build.script',
                                        text: """\
                                            export BUILD_ID=\"${BUILD_ID}\"
                                            export JENKINS_NODE_COOKIE=\"${JENKINS_NODE_COOKIE}\"
                                            export DH_VERBOSE=1 DH_QUIET=0
                                            export DEB_BUILD_OPTIONS='verbose all_tests'
                                            dpkg-buildpackage -jauto -us -uc -b
                                        """.stripIndent()
                                    sh "osc -v -A ${env.OBS_INSTANCE} build ${OSC_BUILD_ARGS} --download-api-only --local-package --no-service --trust-all-projects --build-uid=caller --alternative-project=${env.OBS_TARGET_PROJECT} ${env.OBS_TARGET_REPO} ${env.OBS_TARGET_ARCH}"
                                }
                            }
                        }
                    } // stages
                } // OSC

                stage('Code Stats') {
                    steps {
                        script {
                            if (env.CHANGE_ID == null) { // Not when this is a Pull Request
                                sh 'sloccount --duplicates --wide --details vyatta-cfg-dataplane > sloccount.sc'
                                sloccountPublish pattern: '**/sloccount.sc'
                            }
                        }
                    }
                }

                stage('Commit Size') {
                    when {
                        allOf {
                            // Only if this is a Pull Request
                            expression { env.CHANGE_ID != null }
                            expression { env.CHANGE_TARGET != null }
                        }
                    }
                    steps {
                        catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                            dir('vyatta-cfg-dataplane') {
                                sh "./scripts/commit_size_check.sh upstream/${env.CHANGE_TARGET} origin/${env.BRANCH_NAME}"
                            }
                        }
                    }
                }

                stage('gitlint') {
                    when {
                        allOf {
                            // Only if this is a Pull Request
                            expression { env.CHANGE_ID != null }
                            expression { env.CHANGE_TARGET != null }
                        }
                    }
                    agent {
                        docker { image 'jorisroovers/gitlint'
                                 args '--entrypoint=""'
                                 reuseNode true
                        }
                    }
                    steps {
                        catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                            dir('vyatta-cfg-dataplane') {
                                sh "gitlint --commits upstream/${env.CHANGE_TARGET}..origin/${env.BRANCH_NAME}"
                            }
                        }
                    }
                }

            } // parallel
        } // run tests
    } // stages

    post {
        always {
            sh 'rm -f *.deb'
            sh "osc chroot --wipe --force --root ${env.OSC_BUILD_ROOT}"
            deleteDir()
        }
        success {
            echo 'Winning'
        }
        failure {
            echo 'Argh... something went wrong'
            emailext (
                subject: "FAILED: Job '${env.JOB_NAME} [${env.BUILD_NUMBER}]'",
                body: """<p>FAILED: Job '${env.JOB_NAME} [${env.BUILD_NUMBER}]':</p>
                         <p>Check console output at "<a href="${env.BUILD_URL}">${env.JOB_NAME} [${env.BUILD_NUMBER}]</a>"</p>""",
                recipientProviders: [culprits()]
            )
        }
    }
}
