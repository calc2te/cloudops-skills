# Provider with the organisation's tags baked in.
#
# One root module = one Project, Team and Environment, so those live here. `Service` differs per
# resource and is set on each resource from var.service_id.
#
# Values come from the repository's "## AWS standards" block (reference/configuration.md).
# Replace: <PROFILE> <REGION> <PROJECT> <TEAM> <ENV_TAG>

provider "aws" {
  profile = "<PROFILE>"
  region  = "<REGION>"

  default_tags {
    tags = {
      Project     = "<PROJECT>" # closed list
      Team        = "<TEAM>"    # closed list
      Environment = "<ENV_TAG>" # production | staging | qa | development
      ManagedBy   = "terraform" # lowercase — "Terraform" is a different value in cost reports
    }
  }

  # Only keys another process writes on purpose. Everything else stays visible as drift in plan.
  ignore_tags {
    keys = ["Lifecycle"] # delete-candidate marks set by cleanup scripts
  }
}
