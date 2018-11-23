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
		stage('ArchIso') {
			steps {
				sh "tests/create_archiso.sh"
			}
		}
		stage('Test') {
			steps {
				sh "tests/test_installation.sh"
			}
		}
	}
}
