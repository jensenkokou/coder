terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "1.0.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.31.0"
    }
  }
}

provider "coder" {
}


locals {
  domain                     = "mil"
  AZURE_CLOUD_NAME           = "AzureUSGovernment"
  ARM_ENVIRONMENT            = "usgovernment"
  repo_url_parts             = split("/", data.coder_parameter.repo.value)
  folder_name_raw            = try(element(split("/", data.coder_parameter.repo.value), length(split("/", data.coder_parameter.repo.value)) - 1), "")
  folder_name                = replace(local.folder_name_raw, "/\\.git$/", "")
  repo_owner_name            = try(element(split("/", data.coder_parameter.repo.value), length(split("/", data.coder_parameter.repo.value)) - 2), "")
  dotfiles_dir               = "/home/coder/.dotfiles"
  gitlab_url                 = "https://gitlab.mda.${local.domain}"
  image                      = "artifactory.mda.${local.domain}/gm-tma-docker-prod-local/custom/coder-workspace:v0.0.9"
  gitlab_workflow_token_file = "/home/coder/gitlab-workflow-token.txt"
  marketplace                = "https://code-marketplace.dso.gm.mda.${local.domain}"
}

variable "namespace" {
  type        = string
  description = "The Kubernetes namespace to create workspaces in (must exist prior to creating workspaces). If the Coder host is itself running as a Pod on the same Kubernetes cluster as you are deploying workspaces to, set this to the same namespace."
}

variable "use_kubeconfig" {
  type        = bool
  description = <<-EOF
  Use host kubeconfig? (true/false)

  Set this to false if the Coder host is itself running as a Pod on the same
  Kubernetes cluster as you are deploying workspaces to.

  Set this to true if the Coder host is running outside the Kubernetes cluster
  for workspaces.  A valid "~/.kube/config" must be present on the Coder host.
  EOF
  default     = false
}



data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU"
  description  = "The number of CPU cores"
  default      = "2"
  icon         = "/icon/memory.svg"
  mutable      = true
  option {
    name  = "2 Cores"
    value = "2"
  }
  option {
    name  = "4 Cores"
    value = "4"
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory"
  description  = "The amount of memory in GB"
  default      = "2"
  icon         = "/icon/memory.svg"
  mutable      = true
  option {
    name  = "2 GB"
    value = "2"
  }
  option {
    name  = "4 GB"
    value = "4"
  }
  option {
    name  = "6 GB"
    value = "6"
  }
}

data "coder_parameter" "home_disk_size" {
  name         = "home_disk_size"
  display_name = "Home disk size"
  description  = "The size of the home disk in GB"
  default      = "10"
  type         = "number"
  icon         = "/emojis/1f4be.png"
  mutable      = false
  validation {
    min = 1
    max = 100
  }
}

data "coder_parameter" "repo" {
  name        = "Source Code Repositories (optional)"
  type        = "string"
  description = "What source code repositories do you want to clone? e.g., https://gitlab.mda.mil/tma/tenants/your-group/your-project.git,https://gitlab.example.com/coder/coder/-/tree/feat/example"
  mutable     = true
  icon        = "/icon/git.svg"
  default     = ""
  order       = 5
  validation {
    regex = "^($|https://gitlab\\.mda\\.[^/]+/[^/]+(?:/[^/]+)*/[^/]+\\.git(?:,\\s*https://gitlab\\.mda\\.[^/]+/[^/]+(?:/[^/]+)*/[^/]+\\.git)*)"
    error = "Repository URLs must start with 'https://gitlab.mda' and end with '.git', separated by commas"
  }
}

module "git-clone" {
  source   = "artifactory.mda.mil/gm-tma-tf-dev-virtual__coder/git-clone/coder"
  version  = "1.0.23"
  agent_id = coder_agent.main.id
  git_providers = {
    "https://gitlab.mda.mil/" = {
      provider = "gitlab"
    }
  }

  for_each = toset(split(",", trimspace(replace(data.coder_parameter.repo.value, "/\\s*,\\s*/", ","))))


  url = each.value
}


data "coder_parameter" "dotfiles_url" {
  name        = "Dotfiles URL (optional)"
  description = "Personalize your workspace e.g., https://gitlab.mda.${local.domain}/username/dotfiles.git"
  type        = "string"
  default     = ""
  mutable     = true
  icon        = "/icon/git.svg"
  order       = 7
  validation {
    regex = "^(|https://gitlab\\.mda\\.[^/]+/[^/]+(?:/[^/]+)*/[^/]+\\.git)$"
    error = "Repository URL must start with 'https://gitlab.mda' and end with '.git'"
  }
}

provider "kubernetes" {
  # Authenticate via ~/.kube/config or a Coder-specific ServiceAccount, depending on admin preferences
  config_path = var.use_kubeconfig == true ? "~/.kube/config" : null
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# Require git authentication to use this template
data "coder_external_auth" "gitlab" {
  id = "primary-gitlab"
}

data "coder_external_auth" "jfrog" {
  id = "jfrog"
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
  env = {
    EXTENSIONS_GALLERY = "{\"serviceUrl\":\"${local.marketplace}/api\", \"itemUrl\":\"${local.marketplace}/item\", \"resourceUrlTemplate\": \"${local.marketplace}/files/{publisher}/{name}/{version}/{path}\"}",
    #GITLAB_TOKEN : data.coder_external_auth.gitlab.access_token
    GITLAB_WORKFLOW_TOKEN_FILE : local.gitlab_workflow_token_file
  }
  dir                     = "/home/coder"
  startup_script_behavior = "blocking"
  startup_script          = <<EOT
#!/bin/bash
set -eu -o pipefail
# start code-server
code-server --auth none --port 13337 --disable-file-downloads --disable-file-uploads >/tmp/code-server.log 2>&1 &
USER_DIR="$HOME/.local/share/code-server/User"
mkdir -p "$USER_DIR"
TOKEN=$(coder external-auth access-token primary-gitlab)
echo "GitLab Token Setup"
echo "$TOKEN" > /home/coder/gitlab-workflow-token.txt
code-server --install-extension GitLab.gitlab-workflow --force
git config --global credential.useHttpPath true
git config --global user.name "${data.coder_workspace_owner.me.name}"
git config --global user.email "${data.coder_workspace_owner.me.email}"
git config --global init.defaultBranch main
git config --global alias.mr '!sh -c "git fetch $1 merge-requests/$2/head:mr-$1-$2 && git checkout mr-$1-$2" -'

# Allow synchronization between scripts.
touch /tmp/.coder-startup-script.done

# Check if the directory exists At workspace creation as the coder_script runs in parallel so clone might not exist yet.
while [[ ! -e "/tmp/.coder-script-dotfiles-install.done" ]]; do
  echo "waiting for dotfiles script"
  sleep 1
done
source $HOME/.bashrc
echo "Workspace setup Complete"
EOT

  # The following metadata blocks are optional. They are used to display
  # information about your workspace in the dashboard. You can remove them
  # if you don't want to display any information.
  # For basic resources, you can use the `coder stat` command.
  # If you need more control, you can write your own script.
  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "4_cpu_usage_host"
    script       = "coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage (Host)"
    key          = "5_mem_usage_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Load Average (Host)"
    key          = "6_load_host"
    # get load avg scaled by number of cores
    script   = <<EOT
      echo "`cat /proc/loadavg | awk '{ print $1 }'` `nproc`" | awk '{ printf "%0.2f", $1/$2 }'
    EOT
    interval = 60
    timeout  = 1
  }
}

# code-server
resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "code-server"
  icon         = "/icon/code.svg"
  url          = "http://localhost:13337?folder=/home/coder"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 3
    threshold = 10
  }
}

resource "coder_script" "dotfiles-install" {
  agent_id           = coder_agent.main.id
  display_name       = "dotfiles-install"
  script             = <<EOF
while ! command -v code-server > /dev/null 2>&1; do
  echo "code-server not available yet"
  sleep 1
done
while [[ ! -e "/tmp/.coder-startup-script.done" ]]; do
  echo "waiting for startup script"
  sleep 1
done
if [[ ! -z "${data.coder_parameter.dotfiles_url.value}" ]]; then
  if [[ ! -d "${local.dotfiles_dir}" ]] || [[ -z "$(ls -A ${local.dotfiles_dir})" ]]; then
    echo "Cloning dotfiles repo..."
    coder dotfiles -y ${data.coder_parameter.dotfiles_url.value}
  else
    echo "Dotfiles directory exists. Checking if it's a valid git repo..."
    if [[ -d "${local.dotfiles_dir}/.git" ]]; then
      echo "Directory is a valid git repo. Pulling latest changes..."
      cd ${local.dotfiles_dir}
      git pull
    else
      echo "Directory is not a valid git repo. Cleaning up and cloning dotfiles..."
      rm -rf ${local.dotfiles_dir}/*
      coder dotfiles -y ${data.coder_parameter.dotfiles_url.value}
    fi
  fi
fi
TOKEN=$(coder external-auth access-token primary-gitlab)
echo "GitLab Token Setup"
echo "$TOKEN" > /home/coder/gitlab-workflow-token.txt
if [ ! -e ~/.bashrc ]; then
  touch ~/.bashrc
fi
trap 'touch /tmp/.coder-script-dotfiles-install.done' EXIT
echo "Dotfiles Script finished."
    EOF
  depends_on         = [coder_agent.main]
  timeout            = 300
  start_blocks_login = true
  run_on_start       = true

}

resource "coder_script" "refresh_gitlab_token" {
  agent_id     = coder_agent.main.id
  display_name = "Refresh gitlab token"
  icon         = "/icon/gitlab.svg"
  cron         = "10 * * * *"
  log_path     = "/tmp/mycron-log.log"
  script       = <<EOT
    #!/bin/sh
    while [ ! -f "/tmp/.coder-script-dotfiles-install.done" ]; do
      echo "waiting for dotfiles script"
      sleep 1
    done
    TOKEN=$(coder external-auth access-token primary-gitlab)
    echo "$TOKEN" > /home/coder/gitlab-workflow-token.txt
    EOT

  depends_on = [coder_script.dotfiles-install]
}


resource "kubernetes_persistent_volume_claim" "home" {
  metadata {
    name      = "coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}-home"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-pvc"
      "app.kubernetes.io/instance" = "coder-pvc-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}"
      "app.kubernetes.io/part-of"  = "coder"
      //Coder-specific labels.
      "com.coder.resource"       = "true"
      "com.coder.workspace.id"   = data.coder_workspace.me.id
      "com.coder.workspace.name" = data.coder_workspace.me.name
      "com.coder.user.id"        = data.coder_workspace_owner.me.id
      "com.coder.user.username"  = data.coder_workspace_owner.me.name
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "${data.coder_parameter.home_disk_size.value}Gi"
      }
    }
  }
}

resource "kubernetes_deployment" "main" {
  count = data.coder_workspace.me.start_count
  depends_on = [
    kubernetes_persistent_volume_claim.home
  ]
  wait_for_rollout = false
  metadata {
    name      = "coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-workspace"
      "app.kubernetes.io/instance" = "coder-workspace-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}"
      "app.kubernetes.io/part-of"  = "coder"
      "com.coder.resource"         = "true"
      "com.coder.workspace.id"     = data.coder_workspace.me.id
      "com.coder.workspace.name"   = data.coder_workspace.me.name
      "com.coder.user.id"          = data.coder_workspace_owner.me.id
      "com.coder.user.username"    = data.coder_workspace_owner.me.name
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }

  spec {
    # replicas = data.coder_workspace.me.start_count
    replicas = 1
    selector {
      match_labels = {
        "app.kubernetes.io/name" = "coder-workspace"
      }
    }
    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "coder-workspace"
        }
      }
      spec {

        image_pull_secrets {
          name = "pull-secret"
        }
        security_context {
          run_as_user = 1000
          fs_group    = 1000
        }

        container {
          name              = "dev"
          image             = local.image
          image_pull_policy = "IfNotPresent"
          command           = ["/bin/sh", "-c"]
          args = [<<EOT
          openssl s_client -showcerts -connect coder.dso.gm.mda.mil:443 </dev/null | \
          openssl x509 > /tmp/coder.crt && \
          sudo cp /tmp/coder.crt /usr/local/share/ca-certificates/coder.crt && \
          openssl s_client -showcerts -connect code-marketplace.dso.gm.mda.mil:443 </dev/null 2>/dev/null | \
          openssl x509 -outform PEM > /tmp/cm.crt && \
          sudo cp /tmp/cm.crt /usr/local/share/ca-certificates/cm.crt && \
          sudo update-ca-certificates && \
          ${coder_agent.main.init_script}
          EOT
          ]
          security_context {
            run_as_user = "1000"
          }
          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main.token
          }
          env {
            name  = "OPENSSL_FORCE_FIPS_MODE"
            value = "0"
          }
          env {
            name  = "AZURE_CLOUD_NAME"
            value = local.AZURE_CLOUD_NAME
          }
          env {
            name  = "ARM_ENVIRONMENT"
            value = local.ARM_ENVIRONMENT
          }
          env {
            name  = "NODE_EXTRA_CA_CERTS"
            value = "/etc/ssl/certs/ca-certificates.crt"
          }
          env {
            name  = "GITLAB_WORKFLOW_INSTANCE_URL"
            value = local.gitlab_url
          }
          env {
            name  = "GITLAB_HOST"
            value = local.gitlab_url
          }
          resources {
            requests = {
              "cpu"    = "250m"
              "memory" = "512Mi"
            }
            limits = {
              "cpu"    = "${data.coder_parameter.cpu.value}"
              "memory" = "${data.coder_parameter.memory.value}Gi"
            }
          }
          volume_mount {
            mount_path = "/home/coder"
            name       = "home"
            read_only  = false
          }
        }

        volume {
          name = "home"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.home.metadata.0.name
            read_only  = false
          }
        }

        node_selector = { "kubernetes.azure.com/agentpool" = "user" }

        affinity {
          // This affinity attempts to spread out all workspace pods evenly across
          // nodes.
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 1
              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"
                label_selector {
                  match_expressions {
                    key      = "app.kubernetes.io/name"
                    operator = "In"
                    values   = ["coder-workspace"]
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

resource "coder_metadata" "workspace_info" {
  count       = data.coder_workspace.me.start_count
  resource_id = kubernetes_deployment.main[0].id
  icon        = "${data.coder_workspace.me.access_url}/icon/k8s.png"
  daily_cost  = 150
  item {
    key   = "repo cloned"
    value = "${local.repo_owner_name}/${local.folder_name}"
  }
  item {
    key   = "extensions marketplace"
    value = local.marketplace
  }

  item {
    key   = "image"
    value = local.image
  }

}

resource "coder_metadata" "workspace_pvc" {
  resource_id = kubernetes_persistent_volume_claim.home.id
  daily_cost  = 50
  icon = data.coder_parameter.home_disk_size.icon
  item {
    key   = "Disk Size"
    value = data.coder_parameter.home_disk_size.value
  }
}

module "coder-login" {
  source     = "artifactory.mda.mil/gm-tma-tf-dev-virtual__coder/coder-login/coder"
  version    = "1.0.17"
  agent_id   = coder_agent.main.id
  depends_on = [coder_script.dotfiles-install]
}


module "artifactory-login-custom" {
  source                = "artifactory.mda.mil/gm-tma-tf-dev-virtual__coder-custom/jfrog-oauth/coder"
  version               = "0.0.6"
  agent_id              = coder_agent.main.id
  jfrog_url             = "https://artifactory.mda.${local.domain}"
  configure_code_server = false
  username_field        = "username"
  package_managers = {
    "pypi" : "gm-tma-python-pypi-remote"
    "docker" : "gm-tma-docker-dev-local"
    "terraform" : "gm-tma-tf-dev-virtual"
  }
  files_to_wait_for = ["/home/coder/.bashrc", "/tmp/.coder-script-dotfiles-install.done"]
  jfrog_server_id   = "mda"
}
 this was a main.tf as well. 
