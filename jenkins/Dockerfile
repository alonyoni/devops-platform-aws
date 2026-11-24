# Jenkins controller image with pre-installed tools
# Build: docker build -t jenkins-controller:latest .
# Push:  docker tag jenkins-controller:latest ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/devops-platform/jenkins-agent:latest

FROM jenkins/jenkins:2.440.3-lts-jdk17

USER root

# Install OS dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    wget \
    unzip \
    git \
    jq \
    python3 \
    python3-pip \
    python3-venv \
    ca-certificates \
    gnupg \
    lsb-release \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------
# Install Docker CLI (daemon runs on the host via socket)
# -----------------------------------------------------------------------
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
       | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
       https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------
# Install kubectl
# -----------------------------------------------------------------------
ARG KUBECTL_VERSION=v1.29.2
RUN curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl

# -----------------------------------------------------------------------
# Install Helm
# -----------------------------------------------------------------------
ARG HELM_VERSION=v3.14.2
RUN curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    | tar -zx --strip-components=1 -C /usr/local/bin linux-amd64/helm \
    && chmod +x /usr/local/bin/helm

# -----------------------------------------------------------------------
# Install AWS CLI v2
# -----------------------------------------------------------------------
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws

# -----------------------------------------------------------------------
# Install Terraform
# -----------------------------------------------------------------------
ARG TERRAFORM_VERSION=1.7.4
RUN curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
    -o /tmp/terraform.zip \
    && unzip -q /tmp/terraform.zip -C /usr/local/bin \
    && chmod +x /usr/local/bin/terraform \
    && rm -f /tmp/terraform.zip

# -----------------------------------------------------------------------
# Install Trivy (container image vulnerability scanner)
# -----------------------------------------------------------------------
ARG TRIVY_VERSION=0.49.1
RUN curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
    | tar -zx -C /usr/local/bin trivy \
    && chmod +x /usr/local/bin/trivy

# -----------------------------------------------------------------------
# Install SonarQube Scanner
# -----------------------------------------------------------------------
ARG SONAR_SCANNER_VERSION=5.0.1.3006
RUN curl -fsSL "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux.zip" \
    -o /tmp/sonar-scanner.zip \
    && unzip -q /tmp/sonar-scanner.zip -d /opt \
    && mv "/opt/sonar-scanner-${SONAR_SCANNER_VERSION}-linux" /opt/sonar-scanner \
    && ln -s /opt/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner \
    && rm -f /tmp/sonar-scanner.zip

# -----------------------------------------------------------------------
# Install yq (YAML processor — used to update image tags in GitOps repo)
# -----------------------------------------------------------------------
ARG YQ_VERSION=v4.42.1
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
    -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# Add jenkins user to docker group (so it can use docker socket)
RUN groupadd -f docker && usermod -aG docker jenkins

# Copy plugin list for offline installs (optional)
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt

# Switch back to jenkins user
USER jenkins

# Install plugins from list
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Verify tool installations
RUN docker --version \
    && kubectl version --client \
    && helm version \
    && aws --version \
    && terraform version \
    && trivy --version \
    && yq --version
