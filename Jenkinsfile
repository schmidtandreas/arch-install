pipeline {
	agent any
	options {
		skipDefaultCheckout(true)
	}
	stages {
		stage('Checkout') {
			steps {
				checkout scm
			}
		}
		stage('ArchIso Smart') {
			agent {
				docker {
					image "base/archlinux"
					args "-u root --privileged -v /tmp:/tmp"
				}
			}
			steps {
				git 'https://github.com/schmidtandreas/arch-install'
				sh "./tests/create_archlive.sh"
			}
		}
		stage('Test') {
			steps {
				sh "tests/test_installation.sh"
			}
		}
	}
}
