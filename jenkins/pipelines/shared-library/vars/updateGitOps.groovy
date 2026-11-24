/**
 * Shared Library: updateGitOps
 * Clones the GitOps repo and updates the image tag using yq,
 * then pushes the change back. ArgoCD detects the change and syncs.
 *
 * Usage:
 *   updateGitOps(
 *     repo: "https://github.com/your-org/gitops-repo.git",
 *     credentialsId: "github-credentials",
 *     environment: "dev",
 *     appName: "app",
 *     imageTag: "v1.2.3",
 *     imageRepository: "123.dkr.ecr.us-east-1.amazonaws.com/devops-platform/app"
 *   )
 */
def call(Map config) {
    def repo          = config.repo          ?: error("updateGitOps: 'repo' is required")
    def credId        = config.credentialsId ?: "github-credentials"
    def environment   = config.environment   ?: "dev"
    def appName       = config.appName       ?: error("updateGitOps: 'appName' is required")
    def imageTag      = config.imageTag      ?: error("updateGitOps: 'imageTag' is required")
    def imageRepo     = config.imageRepository ?: ""
    def valuesPath    = config.valuesPath    ?: "environments/${environment}/${appName}/values.yaml"
    def gitopsDir     = "gitops-${UUID.randomUUID().toString()[0..7]}"

    withCredentials([usernamePassword(
        credentialsId: credId,
        usernameVariable: "GIT_USER",
        passwordVariable: "GIT_TOKEN"
    )]) {
        sh """
            echo "==> Cloning GitOps repo: ${repo}"
            git clone https://\${GIT_USER}:\${GIT_TOKEN}@${repo.replace("https://", "")} ${gitopsDir}
            cd ${gitopsDir}

            git config user.email "jenkins@devops-platform.internal"
            git config user.name "Jenkins CI"

            echo "==> Updating ${valuesPath}"
            yq e '.image.tag = "${imageTag}"' -i ${valuesPath}

            ${imageRepo ? "yq e '.image.repository = \"${imageRepo}\"' -i ${valuesPath}" : ""}

            echo "==> Diff:"
            git diff

            git add ${valuesPath}
            git commit -m "ci(${appName}): deploy ${imageTag} to ${environment}

Jenkins Build: \${BUILD_URL:-N/A}"

            git push origin main

            echo "==> GitOps update pushed. ArgoCD will sync shortly."
        """
    }

    // Clean up cloned directory
    sh "rm -rf ${gitopsDir}"
}
