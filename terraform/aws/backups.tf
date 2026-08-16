# Snapshots of the data volume: they cover a lost instance or disk, not a bad
# migration — that is what `make backup` on the instance is for.

data "aws_iam_policy_document" "dlm_assume" {
  count = var.enable_daily_snapshots ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  count = var.enable_daily_snapshots ? 1 : 0

  name               = "${local.name}-dlm-role"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume[0].json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "dlm" {
  count = var.enable_daily_snapshots ? 1 : 0

  role       = aws_iam_role.dlm[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "data" {
  count = var.enable_daily_snapshots ? 1 : 0

  description        = "Daily snapshots of ${local.name} data volume"
  execution_role_arn = aws_iam_role.dlm[0].arn
  state              = "ENABLED"
  tags               = local.tags

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Name = "${local.name}-data" }

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        # Off-hours in UTC, after the daily database jobs the cloud runs at night.
        times = ["03:00"]
      }

      retain_rule {
        count = var.snapshot_retention_days
      }

      copy_tags = true
    }
  }
}
