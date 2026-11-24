/**
 * Shared Library: dockerBuild
 * Usage in Jenkinsfile:
 *   dockerBuild(
 *     image: "my-repo/my-app",
 *     tag: "v1.0.0",
 *     context: "app/",
 *     dockerfile: "app/Dockerfile"
 *   )
 */
def call(Map config) {
    def image      = config.image      ?: error("dockerBuild: 'image' is required")
    def tag        = config.tag        ?: "latest"
    def context    = config.context    ?: "."
    def dockerfile = config.dockerfile ?: "Dockerfile"
    def buildArgs  = config.buildArgs  ?: [:]
    def registry   = config.registry   ?: ""

    def fullImage = registry ? "${registry}/${image}:${tag}" : "${image}:${tag}"

    def buildArgsStr = buildArgs.collect { k, v -> "--build-arg ${k}=${v}" }.join(" ")

    sh """
        echo "==> Building Docker image: ${fullImage}"
        docker build \
          ${buildArgsStr} \
          --tag ${fullImage} \
          --file ${dockerfile} \
          ${context}
    """

    return fullImage
}
