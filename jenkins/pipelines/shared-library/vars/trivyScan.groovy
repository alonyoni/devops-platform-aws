/**
 * Shared Library: trivyScan
 * Runs a Trivy container image vulnerability scan.
 * Fails the build on HIGH/CRITICAL unfixed CVEs.
 *
 * Usage:
 *   trivyScan(image: "123.dkr.ecr.us-east-1.amazonaws.com/app:v1.0.0")
 *   trivyScan(image: "app:latest", failOnSeverity: "CRITICAL")
 */
def call(Map config) {
    def image          = config.image          ?: error("trivyScan: 'image' is required")
    def failOnSeverity = config.failOnSeverity ?: "HIGH,CRITICAL"
    def ignoreUnfixed  = config.ignoreUnfixed  != null ? config.ignoreUnfixed : true
    def outputFile     = config.outputFile     ?: "trivy-report.json"

    def ignoreFlag = ignoreUnfixed ? "--ignore-unfixed" : ""

    // Informational scan — show all severities, don't fail
    sh """
        echo "==> Trivy scan summary (all severities):"
        trivy image \
          --format table \
          --exit-code 0 \
          --severity LOW,MEDIUM,HIGH,CRITICAL \
          ${image} || true
    """

    // Strict scan — fail on configured severity
    sh """
        echo "==> Trivy strict scan (fail on: ${failOnSeverity})"
        trivy image \
          --format json \
          --output ${outputFile} \
          --exit-code 1 \
          --severity ${failOnSeverity} \
          ${ignoreFlag} \
          ${image}
    """

    archiveArtifacts artifacts: outputFile, allowEmptyArchive: true
}
