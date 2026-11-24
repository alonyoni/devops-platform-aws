/**
 * Shared Library: ecrLogin
 * Authenticates Docker to AWS ECR.
 * Usage:
 *   ecrLogin(region: "us-east-1", accountId: "123456789012")
 */
def call(Map config) {
    def region    = config.region    ?: "us-east-1"
    def accountId = config.accountId ?: error("ecrLogin: 'accountId' is required")
    def registry  = "${accountId}.dkr.ecr.${region}.amazonaws.com"

    sh """
        echo "==> Logging in to ECR: ${registry}"
        aws ecr get-login-password --region ${region} \
          | docker login --username AWS --password-stdin ${registry}
    """

    return registry
}
