variable "alert_email" {
  description = "Optional email receiver for Azure Monitor alerts (ALERT_EMAIL)."
  type        = string
  default     = ""
}

variable "critical_job_deadline_hours" {
  description = "Hours without a successful J3 run before the critical-job alert fires."
  type        = number
  default     = 1

  validation {
    condition     = var.critical_job_deadline_hours >= 1 && var.critical_job_deadline_hours <= 48 && floor(var.critical_job_deadline_hours) == var.critical_job_deadline_hours
    error_message = "critical_job_deadline_hours must be a whole number between 1 and 48."
  }
}

locals {
  alert_definitions = {
    workflow_failed = {
      name                      = "alert-workflow-failed"
      description               = "A Logic Apps wf-j* workflow run failed in the last five minutes."
      query                     = file("${path.module}/alerts/workflow-failed.kql")
      severity                  = 1
      window_duration           = "PT5M"
      query_time_range_override = "PT5M"
      metric_measure_column     = "FailedRuns"
      operator                  = "GreaterThan"
      threshold                 = 0
    }
    critical_job_deadline = {
      name                      = "alert-critical-job-did-not-succeed-by-deadline"
      description               = "No successful J3 run was observed within the configured deadline."
      query                     = replace(file("${path.module}/alerts/critical-job-deadline.kql"), "__DEADLINE_HOURS__", tostring(var.critical_job_deadline_hours))
      severity                  = 1
      window_duration           = "PT5M"
      query_time_range_override = "P2D"
      metric_measure_column     = "SuccessfulRuns"
      operator                  = "Equal"
      threshold                 = 0
    }
    runbook_failed = {
      name                      = "alert-runbook-failed"
      description               = "An Automation job failed, was suspended, or was stopped."
      query                     = file("${path.module}/alerts/runbook-failed.kql")
      severity                  = 1
      window_duration           = "PT5M"
      query_time_range_override = "PT5M"
      metric_measure_column     = "FailedJobs"
      operator                  = "GreaterThan"
      threshold                 = 0
    }
    hybrid_job_stuck = {
      name                      = "alert-hybrid-job-stuck"
      description               = "An Automation job has remained queued for over ten minutes or J3 timed out."
      query                     = file("${path.module}/alerts/hybrid-job-stuck.kql")
      severity                  = 1
      window_duration           = "PT5M"
      query_time_range_override = "PT15M"
      metric_measure_column     = "StuckOrTimedOutJobs"
      operator                  = "GreaterThan"
      threshold                 = 0
    }
    partner_connection_errors = {
      name                      = "alert-partner-connection-errors"
      description               = "At least three FTP or SFTP actions failed in the last fifteen minutes."
      query                     = file("${path.module}/alerts/partner-connection-errors.kql")
      severity                  = 2
      window_duration           = "PT5M"
      query_time_range_override = "PT15M"
      metric_measure_column     = "FailedActions"
      operator                  = "GreaterThanOrEqual"
      threshold                 = 3
    }
  }
}

resource "azurerm_monitor_action_group" "alerts" {
  name                = "ag-${var.environment_name}"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "ag${local.token}"
  tags                = local.tags

  dynamic "email_receiver" {
    for_each = var.alert_email == "" ? [] : [var.alert_email]
    content {
      name                    = "alert-email"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "alerts" {
  for_each = local.alert_definitions

  name                      = each.value.name
  resource_group_name       = azurerm_resource_group.main.name
  location                  = var.location
  display_name              = each.value.name
  description               = each.value.description
  severity                  = each.value.severity
  enabled                   = true
  evaluation_frequency      = "PT5M"
  window_duration           = each.value.window_duration
  query_time_range_override = each.value.query_time_range_override
  scopes                    = [module.monitoring.log_analytics_workspace_id]
  auto_mitigation_enabled   = true
  skip_query_validation     = true
  tags                      = local.tags

  criteria {
    query                   = each.value.query
    time_aggregation_method = "Maximum"
    metric_measure_column   = each.value.metric_measure_column
    operator                = each.value.operator
    threshold               = each.value.threshold

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.alerts.id]
  }
}

resource "azurerm_application_insights_workbook" "monitoring" {
  name                = "a61a0a9e-4ab8-4c3a-a89a-298e00a63c17"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  display_name        = "Orchestrator to Logic Apps monitoring"
  description         = "Logic Apps and Automation monitoring for the migration spike."
  source_id           = lower(module.monitoring.application_insights_id)
  data_json           = replace(file("${path.module}/workbook.json"), "__LOG_ANALYTICS_WORKSPACE_ID__", lower(module.monitoring.log_analytics_workspace_id))
  tags                = local.tags
}
