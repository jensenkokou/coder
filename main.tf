terraform {
  required_providers {
    coderd = {
      source = "coder/coderd"
      version = "0.0.4"
    }
  }
}

provider "coderd" {
  url   = var.coder_url
  token = var.coder_ci_token
}

locals {
  is_main_branch = var.git_branch == "main"
}

data "coderd_user" "admin_user" {
  username = "ci-admin"
}

data "coderd_group" "everyone" {
  name = "Everyone"
}

data "coderd_group" "gm_tma" {
  name = "gm-tma"
}

resource "coderd_template" "default-kubernetes-custom" {
  count       = local.is_main_branch ? 1 : 0
  name        = "default-kubernetes-custom"
  description = "Stable/default coder template without docker in docker"
  icon        = "/icon/k8s.png"
  versions = [{
    name        = "stable-${var.git_commit_sha}"
    description = "Stable version."
    directory   = "./stable-template"
    active      = true
  }]
  acl = {
    users = [{
      id   = data.coderd_user.admin_user.id
      role = "admin"
    }]
    groups = [{
      id   = data.coderd_group.everyone.id
      role = "use"
    }]
  }
  depends_on = [ data.coderd_group.everyone, data.coderd_user.admin_user ]
}

# resource "coderd_template" "staging-kubernetes-custom" {
#   count       = local.is_main_branch ? 0 : 1
#   name        = "staging-kubernetes-custom"
#   description = "Staging coder template without docker in docker"
#   icon        = "/icon/k8s.png"
#   versions = [{
#     name        = "staging-${var.git_commit_sha}"
#     description = "Staging version."
#     directory   = "./staging-template"
#     active      = true
#   }]
#   acl = {
#     users = [{
#       id   = data.coderd_user.admin_user.id
#       role = "admin"
#     }]
#     groups = [{
#       id   = data.coderd_group.gm_tma.id
#       role = "use"
#     }]
#   }
# }
